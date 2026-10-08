import Foundation

struct BridgeError: LocalizedError, Sendable {
    let message: String
    var detail: String = ""
    var errorDescription: String? { message }
    static let missingADB = BridgeError(message: "QuestBridge couldn’t locate Android Debug Bridge. Select an ADB executable in Settings.")
    static let invalidPath = BridgeError(message: "This location is outside the headset’s shared storage, or its name is invalid.")
    static let unsupported = BridgeError(message: "This headset doesn’t support the safe filesystem commands QuestBridge needs.")
}

enum DeviceState: String, Sendable { case device, unauthorized, offline, unknown }
struct QuestDevice: Identifiable, Sendable, Equatable {
    let id: String
    var state: DeviceState
    var model: String
    var isQuest: Bool
    var displayName: String { model.isEmpty ? "Android device (\(id))" : model.replacingOccurrences(of: "_", with: " ") }
}

enum RemoteFileType: String, Sendable { case directory, file, symlink, other }
struct RemoteFile: Identifiable, Sendable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    let type: RemoteFileType
    let size: Int64?
    let modificationDate: Date?
    var isDirectory: Bool { type == .directory }
    var typeName: String { isDirectory ? "Folder" : (type == .symlink ? "Symbolic link" : URL(fileURLWithPath: name).pathExtension.uppercased()) }
    var icon: String {
        if isDirectory { return "folder.fill" }
        if type == .symlink { return "link" }
        return ["mp4", "mkv", "mov", "m4v", "webm"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) ? "film" : "doc"
    }
}
struct StorageInfo: Sendable, Equatable { let total: Int64; let available: Int64 }
struct DeviceContext: Sendable, Equatable { let serial: String; let root: String }

enum ConflictPolicy: String, CaseIterable, Sendable { case ask = "Ask every time", replace = "Replace", skip = "Skip", keepBoth = "Keep Both", cancel = "Cancel" }
struct ConflictDecision: Sendable { let policy: ConflictPolicy; let applyToBatch: Bool }
enum TransferDirection: String, Sendable { case upload = "Uploading", download = "Downloading" }
enum TransferStatus: String, Sendable { case pending = "Waiting", running = "Transferring", completed = "Completed", failed = "Failed", cancelled = "Cancelled", skipped = "Skipped" }
struct TransferRequest: Identifiable, Sendable {
    let id: UUID
    let batchID: UUID
    let device: DeviceContext
    let direction: TransferDirection
    let localURL: URL
    let remotePath: String
    var name: String { direction == .upload ? localURL.lastPathComponent : (remotePath as NSString).lastPathComponent }
}
struct TransferItem: Identifiable, Sendable {
    var id: UUID { request.id }
    let request: TransferRequest
    var status: TransferStatus = .pending
    var message = "Waiting in queue"
    var totalBytes: Int64?
    var startedAt: Date?
}
func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
