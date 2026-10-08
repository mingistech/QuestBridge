import Foundation
import Testing
@testable import QuestBridgeCore

actor DiscoveryADB: ADBExecuting {
    var devices: String
    var commands: [[String]] = []
    init(_ devices: String) { self.devices = devices }
    func setDevices(_ value: String) { devices = value }
    func execute(arguments: [String], timeout: Duration, output: (@Sendable (Data) -> Void)?) async throws -> ADBCommandResult {
        commands.append(arguments)
        let text: String
        if arguments == ["devices", "-l"] { text = devices }
        else if arguments.prefix(2) == ["-s", "QUEST"] { text = "Oculus\nQuest 3\neureka\n" }
        else { text = "Google\nPixel\npanther\n" }
        return ADBCommandResult(stdout: Data(text.utf8), stderr: Data(), exitCode: 0)
    }
}
@Suite struct DiscoveryTests {
    @Test func verifiesQuestWithoutMisidentifyingOtherAndroids() async throws {
        let adb = DiscoveryADB("List of devices attached\nQUEST device model:Quest_3\nPHONE device model:Pixel\nLOCKED unauthorized\nOFF offline\n")
        let found = try await DeviceDiscoveryService(adb: adb).discover()
        #expect(found.count == 4)
        #expect(found.filter(\.isQuest).map(\.id) == ["QUEST"])
        let commands = await adb.commands
        #expect(commands.count == 3)
        #expect(commands.dropFirst().allSatisfy { $0.first == "-s" })
        await adb.setDevices("List of devices attached\n")
        #expect(try await DeviceDiscoveryService(adb: adb).discover().isEmpty)
    }
}
