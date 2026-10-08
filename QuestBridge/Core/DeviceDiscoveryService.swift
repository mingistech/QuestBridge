import Foundation

enum DeviceParser {
    static func parse(_ text: String) -> [QuestDevice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List "), !line.hasPrefix("*"),
                  let state = DeviceState(rawValue: fields[1]) else { return nil }
            let model = fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) } ?? ""
            return QuestDevice(id: fields[0], state: state, model: model, isQuest: false)
        }
    }
    static func isQuest(manufacturer: String, model: String, device: String) -> Bool {
        let vendor = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let model = model.lowercased()
        let known = ["hollywood", "eureka", "panther", "seacliff", "monterey"]
        return ["oculus", "meta", "meta platforms technologies", "facebook"].contains(vendor)
            && (model.contains("quest") || known.contains(device.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
    }
}

// adb track-devices forwards the service's four-hex-digit byte-length frames.
// Keep partial UTF-8 and frame headers intact across arbitrary pipe chunks.
struct DeviceTrackParser: Sendable {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [String] {
        buffer.append(data)
        var snapshots: [String] = []
        while buffer.count >= 4 {
            guard let header = String(data: buffer.prefix(4), encoding: .ascii), let length = Int(header, radix: 16) else {
                throw BridgeError(message: "Device tracking returned an unsupported format. Connection polling remains available.")
            }
            guard buffer.count >= length + 4 else { break }
            snapshots.append(String(decoding: buffer.dropFirst(4).prefix(length), as: UTF8.self))
            buffer.removeFirst(length + 4)
        }
        return snapshots
    }
}

struct DeviceDiscoveryService: Sendable {
    let adb: any ADBExecuting
    func discover() async throws -> [QuestDevice] {
        let result = try await adb.execute(arguments: ["devices", "-l"])
        var devices = DeviceParser.parse(result.text)
        for index in devices.indices where devices[index].state == .device {
            let serial = devices[index].id
            do {
                let properties = try await adb.shell("getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.product.device", device: serial)
                let lines = properties.text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard lines.count >= 3 else { continue }
                devices[index].model = lines[1]
                devices[index].isQuest = DeviceParser.isQuest(manufacturer: lines[0], model: lines[1], device: lines[2])
            } catch is CancellationError { throw CancellationError() }
            catch { /* The next poll retries identification; unverified devices remain unavailable. */ }
        }
        return devices
    }
    func monitor(changed: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    await changed()
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                }
            }
            group.addTask {
                // Streaming is an optimization. After bounded retries, polling continues.
                for retry in 0..<5 {
                    if Task.isCancelled { return }
                    let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(16)) { continuation in
                        let task = Task {
                            do {
                                _ = try await adb.execute(arguments: ["track-devices"], timeout: .seconds(86400), output: { continuation.yield($0) })
                            } catch { }
                            continuation.finish()
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                    var parser = DeviceTrackParser()
                    for await chunk in stream {
                        do { if !(try parser.append(chunk)).isEmpty { await changed() } }
                        catch { break }
                    }
                    do { try await Task.sleep(for: .seconds(min(30, 1 << retry))) } catch { return }
                }
            }
            await group.waitForAll()
        }
    }
}
