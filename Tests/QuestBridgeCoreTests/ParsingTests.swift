import Foundation
import Testing
@testable import QuestBridgeCore

@Suite struct PathTests {
    let root = "/storage/emulated/0"
    @Test func boundariesAndNavigation() throws {
        #expect(try RemotePath.normalize(root + "/Movies//", root: root) == root + "/Movies")
        #expect(RemotePath.parent(root, root: root) == root)
        #expect(RemotePath.parent(root + "/Movies/旅行", root: root) == root + "/Movies")
        for path in ["Movies", "/system", root + "/../system", "/storage/emulated/01", root + "/a\0b"] {
            #expect(throws: BridgeError.self) { try RemotePath.normalize(path, root: root) }
        }
        #expect(try RemotePath.child("日本語 ' (test)\n.mkv", of: root, root: root) == root + "/日本語 ' (test)\n.mkv")
        for name in ["..", ".", "a/b", ""] { #expect(throws: BridgeError.self) { try RemotePath.child(name, of: root, root: root) } }
    }
    @Test func escapingRoundTripsThroughPOSIXShell() async throws {
        let runner = ADBProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"))
        for name in ["normal.mp4", "it's (a) film\n.mkv", "$(touch /tmp/should-not-exist);`echo nope`", "日本語", "ends\n"] {
            let result = try await runner.execute(arguments: ["-c", "printf '%s' " + RemotePath.quote(name)])
            #expect(result.text == name)
        }
    }
    @Test func conflictsPreserveExtensionAndCase() {
        #expect(RemotePath.availableName("Video.mkv", existing: ["video.MKV", "Video 2.mkv"]) == "Video 3.mkv")
        #expect(RemotePath.availableName("Folder", existing: ["folder"]) == "Folder 2")
        #expect(RemotePath.availableName("café.mp4", existing: ["cafe\u{301}.mp4"]) == "café 2.mp4")
    }
}
@Suite struct ParserTests {
    @Test func deviceStatesAndUnexpectedOutput() {
        #expect(DeviceParser.parse("List of devices attached\n\n").isEmpty)
        let devices = DeviceParser.parse("List of devices attached\nA device model:Quest_3 transport_id:1\nB unauthorized\nC offline\n* daemon started successfully\nmalformed\nD recovery\n")
        #expect(devices.count == 3)
        #expect(devices.map(\.state) == [.device, .unauthorized, .offline])
        #expect(devices[0].displayName == "Quest 3")
        #expect(!devices[0].isQuest)
        #expect(DeviceParser.isQuest(manufacturer: "Oculus", model: "Quest 3", device: "eureka"))
        #expect(!DeviceParser.isQuest(manufacturer: "Google", model: "Pixel", device: "panther"))
        #expect(!DeviceParser.isQuest(manufacturer: "Unknown", model: "Quest 3", device: "unknown"))
    }
    @Test func fragmentedDeviceTrackingIncludingDisconnect() throws {
        let snapshots = ["A\tdevice\n", "A\tdevice\nB\tunauthorized\n", "", "B\toffline\n"]
        let wire = snapshots.map { String(format: "%04x", $0.utf8.count) + $0 }.joined()
        for chunkSize in 1...17 {
            var parser = DeviceTrackParser(), output: [String] = []
            let data = Array(wire.utf8)
            for i in stride(from: 0, to: data.count, by: chunkSize) {
                output += try parser.append(Data(data[i..<min(i+chunkSize, data.count)]))
            }
            #expect(output == snapshots)
        }
        var parser = DeviceTrackParser()
        #expect(throws: BridgeError.self) { try parser.append(Data("nope".utf8)) }
    }
    @Test func safeMetadataRecords() throws {
        let names = ["Normal.mp4", "Film with spaces.mkv", "日本語.mov", "it's (SBS).mp4", "line\nbreak.mkv", "trailing\n"]
        let wire = names.map { "\($0)\0file\0\(30_000_000_000)\0\(1_700_000_000)\0" }.joined()
        let files = try RemoteParser.listing(Data(wire.utf8), parent: "/sdcard/Movies", root: "/sdcard")
        #expect(files.map(\.name) == names)
        #expect(files.allSatisfy { $0.size == 30_000_000_000 })
        #expect(files.first?.modificationDate != nil)
        #expect(try RemoteParser.listing(Data(), parent: "/sdcard", root: "/sdcard").isEmpty)
        let missing = try RemoteParser.listing(Data("item\0file\0\0\0".utf8), parent: "/sdcard", root: "/sdcard")
        #expect(missing[0].size == nil && missing[0].modificationDate == nil)
        for wire in ["bad", "file\0file\0", "../escape\0file\01\01\0", "file\0nonsense\01\01\0"] {
            #expect(throws: (any Error).self) { try RemoteParser.listing(Data(wire.utf8), parent: "/sdcard", root: "/sdcard") }
        }
    }
    @Test func defensiveStorageParsing() throws {
        let result = try RemoteParser.storage("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/fuse 100000 40000 60000 40% /storage/emulated\n")
        #expect(result.total == 102400000 && result.available == 61440000)
        #expect(throws: BridgeError.self) { try RemoteParser.storage("garbage 128 64") }
        #expect(throws: BridgeError.self) { try RemoteParser.storage("Filesystem 1K-blocks Used Available Use% Mounted on\nx 10 0 20 0% /storage\n") }
    }
}
