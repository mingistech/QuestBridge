import Foundation

protocol RemoteFileSystem: Sendable {
    func connect(serial: String) async throws -> DeviceContext
    func listDirectory(_ path: String, device: DeviceContext) async throws -> [RemoteFile]
    func createDirectory(_ path: String, device: DeviceContext) async throws
    func delete(_ path: String, device: DeviceContext) async throws
    func rename(from: String, to: String, device: DeviceContext) async throws
    func storage(device: DeviceContext) async throws -> StorageInfo
}

enum RemoteParser {
    static func listing(_ data: Data, parent: String, root: String) throws -> [RemoteFile] {
        if data.isEmpty { return [] }
        guard data.last == 0 else { throw BridgeError(message: "The headset returned incomplete folder information. Refresh to try again.") }
        let fields = data.dropLast().split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count.isMultiple(of: 4) else { throw BridgeError(message: "The headset returned invalid folder information.") }
        var files: [RemoteFile] = []
        for i in stride(from: 0, to: fields.count, by: 4) {
            guard let name = String(data: fields[i], encoding: .utf8),
                  let type = RemoteFileType(rawValue: String(decoding: fields[i+1], as: UTF8.self)) else { throw BridgeError.unsupported }
            let size = Int64(String(decoding: fields[i+2], as: UTF8.self))
            let stamp = Double(String(decoding: fields[i+3], as: UTF8.self))
            files.append(RemoteFile(name: name, path: try RemotePath.child(name, of: parent, root: root), type: type,
                                    size: size.flatMap { $0 >= 0 ? $0 : nil }, modificationDate: stamp.map(Date.init(timeIntervalSince1970:))))
        }
        guard Set(files.map(\.path)).count == files.count else { throw BridgeError.unsupported }
        return files
    }
    static func storage(_ text: String) throws -> StorageInfo {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard let header = lines.first, let totalIndex = header.firstIndex(where: { ["1K-blocks", "1024-blocks"].contains($0) }),
              let availableIndex = header.firstIndex(where: { ["Available", "Avail"].contains($0) }) else { throw BridgeError(message: "Storage information is unavailable.") }
        for row in lines.dropFirst() {
            guard row.count > max(totalIndex, availableIndex), let total = Int64(row[totalIndex]), let free = Int64(row[availableIndex]),
                  total > 0, free >= 0, free <= total, total <= Int64.max / 1024 else { continue }
            return StorageInfo(total: total * 1024, available: free * 1024)
        }
        throw BridgeError(message: "Storage information is unavailable.")
    }
}

actor RemoteFileSystemService: RemoteFileSystem {
    let adb: any ADBExecuting
    private var statCommands: [String: String] = [:]
    init(adb: any ADBExecuting) { self.adb = adb }
    func connect(serial: String) async throws -> DeviceContext {
        let result = try await adb.shell("readlink -f /sdcard || readlink -f \"$EXTERNAL_STORAGE\"", device: serial)
        let root = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.hasPrefix("/storage/"), !root.contains("\n") else { throw BridgeError.unsupported }
        _ = try RemotePath.normalize(root, root: root)
        let probe = try await adb.shell("if stat -c '%s %Y' /sdcard >/dev/null 2>&1; then printf stat; elif toybox stat -c '%s %Y' /sdcard >/dev/null 2>&1; then printf 'toybox stat'; else exit 1; fi", device: serial)
        guard ["stat", "toybox stat"].contains(probe.text) else { throw BridgeError.unsupported }
        statCommands[serial] = probe.text
        return DeviceContext(serial: serial, root: root)
    }
    private func checked(_ path: String, device: DeviceContext, parentOnly: Bool = false, mutable: Bool = false) async throws -> String {
        let clean = try RemotePath.normalize(path, root: device.root)
        if mutable && clean == device.root { throw BridgeError.invalidPath }
        let target = parentOnly ? RemotePath.parent(clean, root: device.root) : clean
        let resolved = try await adb.shell("readlink -f -- \(RemotePath.quote(target))", device: device.serial)
        // A symlink within the storage root is still denied: it may change between validation and use.
        guard String(resolved.text.dropLast()) == target else { throw BridgeError.invalidPath }
        return clean
    }
    func listDirectory(_ path: String, device: DeviceContext) async throws -> [RemoteFile] {
        let path = try await checked(path, device: device)
        guard let stat = statCommands[device.serial] else { throw BridgeError.unsupported }
        let script = """
        d=\(RemotePath.quote(path))
        [ -d "$d" ] && [ -r "$d" ] && [ -x "$d" ] || exit 1
        for p in "$d"/* "$d"/.[!.]* "$d"/..?*; do
          [ -e "$p" ] || [ -L "$p" ] || continue
          t=other
          if [ -L "$p" ]; then t=symlink; elif [ -d "$p" ]; then t=directory; elif [ -f "$p" ]; then t=file; fi
          meta=$(\(stat) -c '%s %Y' -- "$p") || exit 1
          size=${meta%% *}; stamp=${meta#* }
          printf '%s\\000%s\\000%s\\000%s\\000' "${p##*/}" "$t" "$size" "$stamp"
        done
        """
        return try RemoteParser.listing(try await adb.shell(script, device: device.serial).stdout, parent: path, root: device.root)
    }
    func createDirectory(_ path: String, device: DeviceContext) async throws {
        let path = try await checked(path, device: device, parentOnly: true, mutable: true)
        _ = try await adb.shell("mkdir -- \(RemotePath.quote(path))", device: device.serial)
    }
    func delete(_ path: String, device: DeviceContext) async throws {
        let path = try await checked(path, device: device, parentOnly: true, mutable: true)
        _ = try await adb.shell("rm -rf -- \(RemotePath.quote(path))", device: device.serial)
    }
    func rename(from: String, to: String, device: DeviceContext) async throws {
        let from = try await checked(from, device: device, parentOnly: true, mutable: true)
        let to = try await checked(to, device: device, parentOnly: true, mutable: true)
        // -n prevents overwrites; -T prevents moving inside an existing directory in a race.
        let qFrom = RemotePath.quote(from), qTo = RemotePath.quote(to)
        _ = try await adb.shell("[ ! -e \(qTo) ] && [ ! -L \(qTo) ] && mv -nT -- \(qFrom) \(qTo) && [ ! -e \(qFrom) ] && [ ! -L \(qFrom) ]", device: device.serial)
    }
    func storage(device: DeviceContext) async throws -> StorageInfo {
        try RemoteParser.storage(try await adb.shell("df -k \(RemotePath.quote(device.root))", device: device.serial).text)
    }
}
