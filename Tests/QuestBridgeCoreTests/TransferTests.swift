import Foundation
import Testing
@testable import QuestBridgeCore

actor MemoryFS: RemoteFileSystem {
    var files: [String: RemoteFile] = [:]
    var free: Int64 = 1_000_000_000
    var renamed: [(String, String)] = []
    let root = "/storage/emulated/0"
    func connect(serial: String) -> DeviceContext { DeviceContext(serial: serial, root: root) }
    func listDirectory(_ path: String, device: DeviceContext) -> [RemoteFile] { files.values.filter { ($0.path as NSString).deletingLastPathComponent == path } }
    func createDirectory(_ path: String, device: DeviceContext) { put(path, size: 0, directory: true) }
    func delete(_ path: String, device: DeviceContext) { files = files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }
    func rename(from: String, to: String, device: DeviceContext) throws {
        guard files[to] == nil, files[from] != nil else { throw BridgeError(message: "Conflict") }
        renamed.append((from, to))
        let moving = files.filter { $0.key == from || $0.key.hasPrefix(from + "/") }
        for (path, file) in moving {
            files.removeValue(forKey: path)
            let newPath = to + path.dropFirst(from.count)
            put(newPath, size: file.size ?? 0, directory: file.isDirectory)
        }
    }
    func storage(device: DeviceContext) -> StorageInfo { StorageInfo(total: 1_000_000_000, available: free) }
    func put(_ path: String, size: Int64, directory: Bool = false) {
        files[path] = RemoteFile(name: (path as NSString).lastPathComponent, path: path, type: directory ? .directory : .file, size: size, modificationDate: nil)
    }
    func setFree(_ value: Int64) { free = value }
    func exists(_ path: String) -> Bool { files[path] != nil }
}
actor FakeTransferADB: ADBExecuting {
    let fs: MemoryFS
    var fail = false
    var corrupt = false
    var calls: [[String]] = []
    init(fs: MemoryFS) { self.fs = fs }
    func setFailure(_ value: Bool) { fail = value }
    func setCorrupt(_ value: Bool) { corrupt = value }
    func execute(arguments: [String], timeout: Duration, output: (@Sendable (Data) -> Void)?) async throws -> ADBCommandResult {
        calls.append(arguments)
        if fail { throw BridgeError(message: "Device disconnected") }
        if arguments.contains("push") {
            let source = URL(fileURLWithPath: arguments[arguments.count-2]), destination = arguments.last!
            let manifest = try FileManifest.local(source)
            for (relative, entry) in manifest.entries {
                await fs.put(destination + (relative.isEmpty ? "" : "/" + relative), size: entry.size + (corrupt ? 1 : 0), directory: entry.directory)
            }
        }
        return ADBCommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}
@Suite struct TransferTests {
    func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Film ' (SBS)\n.mkv")
        try Data(repeating: 42, count: 1024).write(to: url)
        return url
    }
    func request(_ url: URL) -> TransferRequest {
        TransferRequest(id: UUID(), batchID: UUID(), device: DeviceContext(serial: "QUEST-A", root: "/storage/emulated/0"), direction: .upload, localURL: url, remotePath: "/storage/emulated/0/Movies")
    }
    @Test func uploadVerifiedAndSelectedDeviceExplicit() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fs = MemoryFS(), request = request(url); let adb = FakeTransferADB(fs: fs)
        let service = TransferService(adb: adb, fs: fs)
        #expect(try await service.perform(request, conflict: { _ in .cancel }, status: { _, _ in }))
        #expect(await fs.exists(request.remotePath + "/" + request.name))
        #expect(await adb.calls.first?.prefix(2) == ["-s", "QUEST-A"])
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    @Test func failedAndCorruptUploadsPreserveOriginal() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for corrupt in [false, true] {
            let fs = MemoryFS(), request = request(url); let adb = FakeTransferADB(fs: fs)
            await fs.put(request.remotePath + "/" + request.name, size: 55)
            await adb.setFailure(!corrupt); await adb.setCorrupt(corrupt)
            let service = TransferService(adb: adb, fs: fs)
            await #expect(throws: BridgeError.self) { try await service.perform(request, conflict: { _ in .replace }, status: { _, _ in }) }
            let files = await fs.listDirectory(request.remotePath, device: request.device)
            #expect(files.count == 1 && files[0].size == 55)
            #expect(await fs.renamed.isEmpty)
        }
    }
    @Test func insufficientStoragePreventsADBPush() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fs = MemoryFS(); await fs.setFree(100)
        let adb = FakeTransferADB(fs: fs); let service = TransferService(adb: adb, fs: fs)
        await #expect(throws: BridgeError.self) { try await service.perform(request(url), conflict: { _ in .cancel }, status: { _, _ in }) }
        #expect(await adb.calls.isEmpty)
    }
    @Test(arguments: [ConflictPolicy.skip, .keepBoth, .replace, .cancel])
    func conflictDecisions(_ policy: ConflictPolicy) async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fs = MemoryFS(), request = request(url); let adb = FakeTransferADB(fs: fs)
        await fs.put(request.remotePath + "/" + request.name, size: 17)
        let service = TransferService(adb: adb, fs: fs)
        if policy == .cancel {
            await #expect(throws: CancellationError.self) { try await service.perform(request, conflict: { _ in policy }, status: { _, _ in }) }
        } else {
            let copied = try await service.perform(request, conflict: { _ in policy }, status: { _, _ in })
            #expect(copied == (policy != .skip))
        }
        let files = await fs.listDirectory(request.remotePath, device: request.device)
        #expect(files.count == (policy == .keepBoth ? 2 : 1))
        if policy == .replace { #expect(files.first?.size == 1024) }
    }
    @Test func recursiveFolderVerification() async throws {
        let file = try fixture(), folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let fs = MemoryFS(), request = request(folder); let adb = FakeTransferADB(fs: fs)
        #expect(try await TransferService(adb: adb, fs: fs).perform(request, conflict: { _ in .cancel }, status: { _, _ in }))
        #expect(await fs.exists(request.remotePath + "/" + request.name + "/empty"))
    }
}

actor QueueService: Transferring {
    var calls = 0, concurrent = 0, maxConcurrent = 0
    var failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func perform(_ request: TransferRequest, conflict: @escaping @Sendable (String) async -> ConflictPolicy,
                 status: @escaping @Sendable (String, Int64?) async -> Void) async throws -> Bool {
        calls += 1; concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent)
        defer { concurrent -= 1 }
        try await Task.sleep(for: .milliseconds(100))
        if failFirst { failFirst = false; throw BridgeError(message: "Disconnected") }
        return true
    }
}
@Suite @MainActor struct QueueTests {
    func requests(_ count: Int) -> [TransferRequest] {
        (0..<count).map { TransferRequest(id: UUID(), batchID: UUID(), device: DeviceContext(serial: "A", root: "/sdcard"), direction: .upload, localURL: URL(fileURLWithPath: "/tmp/\($0).mkv"), remotePath: "/sdcard/Movies") }
    }
    @Test func serializedMultipleFiles() async {
        let queue = TransferQueue(), service = QueueService()
        queue.configure(service); queue.enqueue(requests(3)); await queue.waitUntilIdle()
        #expect(queue.items.allSatisfy { $0.status == .completed })
        #expect(await service.maxConcurrent == 1)
    }
    @Test func cancelNeverSucceedsAndNextFileContinues() async throws {
        let queue = TransferQueue(), service = QueueService(), requests = requests(2)
        queue.configure(service); queue.enqueue(requests)
        try await Task.sleep(for: .milliseconds(30)); queue.cancel(requests[0].id)
        await queue.waitUntilIdle()
        #expect(queue.items[0].status == .cancelled)
        #expect(queue.items[1].status == .completed)
    }
    @Test func failureAndRetry() async {
        let queue = TransferQueue(), service = QueueService(failFirst: true), requests = requests(1)
        queue.configure(service); queue.enqueue(requests); await queue.waitUntilIdle()
        #expect(queue.items[0].status == .failed)
        queue.retry(requests[0].id); await queue.waitUntilIdle()
        #expect(queue.items.last?.status == .completed)
    }
    @Test func disconnectStopsActiveAndPending() async throws {
        let queue = TransferQueue(), service = QueueService()
        queue.configure(service); queue.enqueue(requests(3))
        try await Task.sleep(for: .milliseconds(30)); queue.failDevice("A"); await queue.waitUntilIdle()
        #expect(queue.items.allSatisfy { $0.status == .failed })
        #expect(await service.calls == 1)
    }
}

actor DownloadADB: ADBExecuting {
    let contents: Data
    var fail: Bool
    init(contents: Data, fail: Bool = false) { self.contents = contents; self.fail = fail }
    func execute(arguments: [String], timeout: Duration, output: (@Sendable (Data) -> Void)?) async throws -> ADBCommandResult {
        guard arguments.prefix(3) == ["-s", "QUEST", "pull"], let path = arguments.last else { throw BridgeError(message: "Unexpected command") }
        try contents.write(to: URL(fileURLWithPath: path))
        if fail { throw BridgeError(message: "Disconnected during pull") }
        return ADBCommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}
@Suite struct DownloadTests {
    @Test(arguments: ["success", "size mismatch", "disconnect", "replace"])
    func downloadIsVerifiedBeforePublication(_ mode: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fs = MemoryFS(), path = "/storage/emulated/0/Movies/Test.mkv"
        await fs.put(path, size: 1024)
        let request = TransferRequest(id: UUID(), batchID: UUID(), device: DeviceContext(serial: "QUEST", root: "/storage/emulated/0"), direction: .download, localURL: folder, remotePath: path)
        let destination = folder.appendingPathComponent("Test.mkv")
        if mode == "replace" { try Data("original".utf8).write(to: destination) }
        let adb = DownloadADB(contents: Data(repeating: 23, count: mode == "size mismatch" ? 512 : 1024), fail: mode == "disconnect")
        let service = TransferService(adb: adb, fs: fs)
        if ["size mismatch", "disconnect"].contains(mode) {
            await #expect(throws: BridgeError.self) { try await service.perform(request, conflict: { _ in .replace }, status: { _, _ in }) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        } else {
            #expect(try await service.perform(request, conflict: { _ in .replace }, status: { _, _ in }))
            #expect(try Data(contentsOf: destination).count == 1024)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Test.mkv"])
        }
    }
}
