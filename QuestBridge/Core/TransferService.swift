import Foundation

struct ManifestEntry: Sendable, Equatable { let directory: Bool; let size: Int64 }
struct FileManifest: Sendable, Equatable {
    var entries: [String: ManifestEntry]
    var total: Int64 { entries.values.reduce(0) { $0 + ($1.directory ? 0 : $1.size) } }
    static func local(_ url: URL) throws -> FileManifest {
        var entries: [String: ManifestEntry] = [:]
        func walk(_ current: URL, relative: String) throws {
            let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw BridgeError(message: "Symbolic links and special files aren’t supported. Choose regular files or folders.")
            }
            entries[relative] = ManifestEntry(directory: values.isDirectory == true, size: Int64(values.fileSize ?? 0))
            if values.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil) {
                    try Task.checkCancellation()
                    let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                    try walk(child, relative: path)
                }
            }
        }
        try walk(url, relative: "")
        // Directory inode sizes differ between filesystems and aren't file contents.
        entries = entries.mapValues { ManifestEntry(directory: $0.directory, size: $0.directory ? 0 : $0.size) }
        return FileManifest(entries: entries)
    }
}

protocol Transferring: Sendable {
    func perform(_ request: TransferRequest,
                 conflict: @escaping @Sendable (String) async -> ConflictPolicy,
                 status: @escaping @Sendable (String, Int64?) async -> Void) async throws -> Bool
}

actor TransferService: Transferring {
    let adb: any ADBExecuting
    let fs: any RemoteFileSystem
    init(adb: any ADBExecuting, fs: any RemoteFileSystem) { self.adb = adb; self.fs = fs }

    private func remoteManifest(_ path: String, device: DeviceContext) async throws -> FileManifest {
        let parent = RemotePath.parent(path, root: device.root)
        guard let item = try await fs.listDirectory(parent, device: device).first(where: { $0.path == path }) else {
            throw BridgeError(message: "The transferred file couldn’t be found. Refresh the folder and retry.")
        }
        var entries: [String: ManifestEntry] = [:]
        func walk(_ file: RemoteFile, relative: String) async throws {
            try Task.checkCancellation()
            guard file.type == .file || file.type == .directory, file.isDirectory || file.size != nil else {
                throw BridgeError(message: "This item cannot be transferred safely. Symbolic links and special files are not supported.")
            }
            entries[relative] = ManifestEntry(directory: file.isDirectory, size: file.isDirectory ? 0 : (file.size ?? 0))
            if file.isDirectory {
                for child in try await fs.listDirectory(file.path, device: device) {
                    try await walk(child, relative: relative.isEmpty ? child.name : relative + "/" + child.name)
                }
            }
        }
        try await walk(item, relative: "")
        return FileManifest(entries: entries)
    }

    func perform(_ request: TransferRequest, conflict: @escaping @Sendable (String) async -> ConflictPolicy,
                 status: @escaping @Sendable (String, Int64?) async -> Void) async throws -> Bool {
        try Task.checkCancellation()
        return try await request.direction == .upload ? upload(request, conflict: conflict, status: status) : download(request, conflict: conflict, status: status)
    }

    private func upload(_ request: TransferRequest, conflict: @escaping @Sendable (String) async -> ConflictPolicy,
                        status: @escaping @Sendable (String, Int64?) async -> Void) async throws -> Bool {
        let device = request.device
        let parent = try RemotePath.normalize(request.remotePath, root: device.root)
        await status("Inspecting files…", nil)
        let manifest = try FileManifest.local(request.localURL)
        let existing = try await fs.listDirectory(parent, device: device)
        var name = request.name
        var replacement: String?
        if let match = existing.first(where: { RemotePath.folded($0.name) == RemotePath.folded(name) }) {
            switch await conflict(name) {
            case .skip: return false
            case .cancel, .ask: throw CancellationError()
            case .keepBoth: name = RemotePath.availableName(name, existing: existing.map(\.name))
            case .replace: replacement = match.path
            }
        }
        try Task.checkCancellation()
        let free = try await fs.storage(device: device)
        // Staging deliberately requires space for the complete new copy, including replacements.
        guard manifest.total <= free.available else { throw BridgeError(message: "Your headset doesn’t have enough free storage. This transfer needs \(bytes(manifest.total)) available for a verified copy.") }
        let stage = try RemotePath.child(".questbridge-\(request.id.uuidString).partial", of: parent, root: device.root)
        let destination = try RemotePath.child(name, of: parent, root: device.root)
        let backup = try RemotePath.child(".questbridge-\(request.id.uuidString).backup", of: parent, root: device.root)
        // UUID staging names are checked as well, so retries never overwrite leftovers.
        guard !existing.contains(where: { $0.path == stage || $0.path == backup }) else {
            throw BridgeError(message: "A partial copy from this transfer still exists. Remove it in the file browser before retrying.")
        }
        do {
            await status("Uploading • progress unavailable from this ADB connection", manifest.total)
            _ = try await adb.execute(arguments: ["-s", device.serial, "push", "-Z", request.localURL.path, stage], timeout: .seconds(7 * 86400), output: { _ in })
            try Task.checkCancellation()
            await status("Verifying file sizes…", manifest.total)
            let copied = try await remoteManifest(stage, device: device)
            guard copied == manifest, try FileManifest.local(request.localURL) == manifest else {
                throw BridgeError(message: "Verification failed: the transferred sizes differ or the source changed. The original destination has been preserved.")
            }
            try Task.checkCancellation()
            if let replacement { try await fs.rename(from: replacement, to: backup, device: device) }
            do {
                try await fs.rename(from: stage, to: destination, device: device)
            } catch {
                if let replacement {
                    // A fresh task allows rollback even after the user cancelled the transfer.
                    let fs = self.fs
                    _ = await Task { try? await fs.rename(from: backup, to: replacement, device: device) }.value
                }
                throw error
            }
            if replacement != nil {
                do { try await fs.delete(backup, device: device) }
                catch { throw BridgeError(message: "The new file was verified, but the old backup couldn’t be removed. Review \((backup as NSString).lastPathComponent) in the destination folder.") }
            }
            return true
        } catch {
            let fs = self.fs
            let cleaned = await Task { () -> Bool in
                do { try await fs.delete(stage, device: device); return true } catch { return false }
            }.value
            if !cleaned, !(error is CancellationError) {
                throw BridgeError(message: "Transfer interrupted. A partial file may remain as \((stage as NSString).lastPathComponent). Reconnect, remove that partial copy, and retry.", detail: error.localizedDescription)
            }
            throw error
        }
    }

    private func download(_ request: TransferRequest, conflict: @escaping @Sendable (String) async -> ConflictPolicy,
                          status: @escaping @Sendable (String, Int64?) async -> Void) async throws -> Bool {
        let manager = FileManager.default
        await status("Inspecting headset files…", nil)
        let manifest = try await remoteManifest(request.remotePath, device: request.device)
        let folder = request.localURL
        let names = try manager.contentsOfDirectory(atPath: folder.path)
        var name = request.name
        var replacement: URL?
        if let match = names.first(where: { RemotePath.folded($0) == RemotePath.folded(name) }) {
            switch await conflict(name) {
            case .skip: return false
            case .cancel, .ask: throw CancellationError()
            case .keepBoth: name = RemotePath.availableName(name, existing: names)
            case .replace: replacement = folder.appendingPathComponent(match)
            }
        }
        try Task.checkCancellation()
        let available = try manager.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber
        guard let available, manifest.total <= available.int64Value else { throw BridgeError(message: "Your Mac doesn’t have enough available storage for this download.") }
        let stage = folder.appendingPathComponent(".questbridge-\(request.id.uuidString).partial")
        let backup = folder.appendingPathComponent(".questbridge-\(request.id.uuidString).backup")
        let destination = folder.appendingPathComponent(name)
        guard !manager.fileExists(atPath: stage.path), !manager.fileExists(atPath: backup.path) else { throw BridgeError(message: "A partial download already exists. Remove it before retrying.") }
        do {
            await status("Downloading • progress unavailable from this ADB connection", manifest.total)
            _ = try await adb.execute(arguments: ["-s", request.device.serial, "pull", "-Z", request.remotePath, stage.path], timeout: .seconds(7 * 86400), output: { _ in })
            try Task.checkCancellation()
            await status("Verifying file sizes…", manifest.total)
            guard try FileManifest.local(stage) == manifest else { throw BridgeError(message: "Download verification failed. The copied sizes don’t match the headset.") }
            if let replacement { try manager.moveItem(at: replacement, to: backup) }
            do { try manager.moveItem(at: stage, to: destination) }
            catch {
                if let replacement { try? manager.moveItem(at: backup, to: replacement) }
                throw error
            }
            if replacement != nil { try manager.removeItem(at: backup) }
            return true
        } catch {
            try? manager.removeItem(at: stage)
            throw error
        }
    }
}
