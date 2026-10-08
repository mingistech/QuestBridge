import Foundation
import OSLog
import Darwin

struct ADBCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    var text: String { String(decoding: stdout, as: UTF8.self) }
}
protocol ADBExecuting: Sendable {
    func execute(arguments: [String], timeout: Duration, output: (@Sendable (Data) -> Void)?) async throws -> ADBCommandResult
}
extension ADBExecuting {
    func execute(arguments: [String], timeout: Duration = .seconds(20)) async throws -> ADBCommandResult {
        try await execute(arguments: arguments, timeout: timeout, output: nil)
    }
    func shell(_ script: String, device: String) async throws -> ADBCommandResult {
        try await execute(arguments: ["-s", device, "shell", "sh", "-c", RemotePath.quote(script)])
    }
}

enum ADBResolver {
    static func resolve(custom: String = "", bundle: Bundle = .main) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let resources = bundle.resourceURL?.path ?? ""
        let paths = [resources + "/platform-tools/adb", resources + "/adb/adb", resources + "/adb", custom,
                     "/opt/homebrew/bin/adb", "/usr/local/bin/adb", home + "/Library/Android/sdk/platform-tools/adb"]
        guard let path = paths.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) && !((try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }) else { throw BridgeError.missingADB }
        return URL(fileURLWithPath: path)
    }
}

// Foundation Process and pipe data are accessed under this lock or on their dedicated reader queues.
// This is the sole synchronization boundary for cancellation from Swift tasks and timeout callbacks.
private final class ProcessState: @unchecked Sendable {
    let lock = NSLock()
    var process: Process?
    var cancelled = false
    var timedOut = false
    var stdout = Data()
    var stderr = Data()
    var overflow = false
    let cap = 32 * 1024 * 1024
    func append(_ data: Data, error: Bool, streaming: Bool) {
        lock.withLock {
            if error {
                stderr.append(data)
                if stderr.count > 65536 { stderr.removeFirst(stderr.count - 65536) }
            } else if !streaming {
                if stdout.count + data.count > cap { overflow = true } else { stdout.append(data) }
            }
        }
    }
    func stop(timeout: Bool = false) {
        lock.withLock {
            if timeout { timedOut = true } else { cancelled = true }
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.withLock {
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

// Track all client processes so quitting also cancels ordinary file-management commands.
// The shared ADB server is deliberately outside this registry.
private final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var states: [UUID: ProcessState] = [:]
    private var closing = false
    func register(_ state: ProcessState, id: UUID) {
        let reject = lock.withLock {
            states[id] = state
            return closing
        }
        if reject { state.stop() }
    }
    func remove(_ id: UUID) { _ = lock.withLock { states.removeValue(forKey: id) } }
    func stopAll() {
        let active = lock.withLock { closing = true; return Array(states.values) }
        for state in active { state.stop() }
    }
    var isEmpty: Bool { lock.withLock { states.isEmpty } }
}

struct ADBProcessRunner: ADBExecuting {
    let executable: URL
    static func shutdownClients() async {
        ProcessRegistry.shared.stopAll()
        while !ProcessRegistry.shared.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
    func execute(arguments: [String], timeout: Duration, output: (@Sendable (Data) -> Void)?) async throws -> ADBCommandResult {
        let state = ProcessState(), id = UUID()
        ProcessRegistry.shared.register(state, id: id)
        defer { ProcessRegistry.shared.remove(id) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try run(arguments: arguments, timeout: timeout, output: output, state: state)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { state.stop() }
    }
    private func run(arguments: [String], timeout: Duration, output: (@Sendable (Data) -> Void)?, state: ProcessState) throws -> ADBCommandResult {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                try state.lock.withLock {
                    guard !state.cancelled else { throw CancellationError() }
                    state.process = process
                    try process.run()
                }
                // Close parent write ends so readers receive EOF even during termination.
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                let readers = DispatchGroup()
                for (handle, isError) in [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] {
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { try? handle.close(); readers.leave() }
                        while let data = try? handle.read(upToCount: 16384), !data.isEmpty {
                            state.append(data, error: isError, streaming: output != nil)
                            if !isError { output?(data) }
                        }
                    }
                }
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                let timer = DispatchWorkItem { state.stop(timeout: true) }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, seconds), execute: timer)
                process.waitUntilExit()
                timer.cancel()
                readers.wait()
                return try state.lock.withLock {
                    state.process = nil
                    if state.cancelled { throw CancellationError() }
                    if state.timedOut { throw BridgeError(message: "The headset didn’t respond in time. Check the USB cable and try again.") }
                    if state.overflow { throw BridgeError(message: "This folder returned too much metadata to display. Open a smaller folder.") }
                    let result = ADBCommandResult(stdout: state.stdout, stderr: state.stderr, exitCode: process.terminationStatus)
                    if result.exitCode != 0 {
                        let detail = String(decoding: result.stderr, as: UTF8.self)
                        Logger(subsystem: "QuestBridge", category: "ADB").error("ADB failed: \(detail, privacy: .private)")
                        let lower = detail.lowercased()
                        let message = lower.contains("unauthorized") ? "Put on your headset and approve USB debugging." : lower.contains("permission denied") ? "QuestBridge doesn’t have permission to modify this location." : lower.contains("no space") ? "Your headset doesn’t have enough free storage." : "The ADB operation failed. Check the USB connection, authorization, and available storage, then retry."
                        throw BridgeError(message: message, detail: detail)
                    }
                    return result
                }
    }
}
