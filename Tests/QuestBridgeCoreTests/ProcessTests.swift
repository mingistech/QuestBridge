import Foundation
import Testing
import Darwin
@testable import QuestBridgeCore

@Suite struct ProcessTests {
    let runner = ADBProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/python3"))
    @Test func drainsBothPipes() async throws {
        let result = try await runner.execute(arguments: ["-c", "import os\nfor i in range(128):\n os.write(1,b'x'*8192); os.write(2,b'y'*8192)"], timeout: .seconds(15))
        #expect(result.stdout.count == 1048576)
        #expect(result.stderr.count == 65536)
    }
    @Test func streamingDoesNotAccumulateOutput() async throws {
        let result = try await runner.execute(arguments: ["-c", "import os\nfor i in range(1024): os.write(1,b'x'*65536)"], timeout: .seconds(20), output: { _ in })
        #expect(result.stdout.isEmpty)
    }
    @Test func nonzeroExitIsFailure() async {
        await #expect(throws: BridgeError.self) {
            try await runner.execute(arguments: ["-c", "import sys;sys.stderr.write('permission denied');sys.exit(1)"])
        }
    }
    @Test func timeoutTerminatesProcess() async throws {
        let start = ContinuousClock.now
        await #expect(throws: BridgeError.self) { try await runner.execute(arguments: ["-c", "import time;time.sleep(30)"], timeout: .milliseconds(100)) }
        #expect(start.duration(to: .now) < .seconds(4))
    }
    @Test func cancellationReapsChildEvenWhenSIGTERMIgnored() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("pid")
        let task = Task { try await runner.execute(arguments: ["-c", "import os,time,signal,sys;signal.signal(signal.SIGTERM,signal.SIG_IGN);open(sys.argv[1],'w').write(str(os.getpid()));time.sleep(30)", pidFile.path], timeout: .seconds(20)) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) == -1)
    }
}
