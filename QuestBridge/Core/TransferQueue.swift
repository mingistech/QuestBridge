import Foundation
import Observation

@MainActor @Observable final class TransferQueue {
    private(set) var items: [TransferItem] = []
    private var worker: Task<Void, Never>?
    private var operation: Task<Bool, Error>?
    private var service: (any Transferring)?
    private var batchPolicies: [UUID: ConflictPolicy] = [:]
    var conflictHandler: (@MainActor @Sendable (String) async -> ConflictDecision)?
    var finished: (@MainActor @Sendable (Bool) -> Void)?
    var changed: (@MainActor @Sendable () -> Void)?
    var active: TransferItem? { items.first { $0.status == .running } }
    var hasWork: Bool { items.contains { $0.status == .pending || $0.status == .running } }
    func configure(_ service: any Transferring) { self.service = service }
    func enqueue(_ requests: [TransferRequest]) {
        items.append(contentsOf: requests.map { TransferItem(request: $0) })
        start()
    }
    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), [.pending, .running].contains(items[index].status) else { return }
        let running = items[index].status == .running
        items[index].status = .cancelled
        items[index].message = "Cancelled. Any partial copy is not a completed transfer."
        if running { operation?.cancel() }
    }
    func cancelAll() { for item in items { cancel(item.id) } }
    func failDevice(_ serial: String) {
        for index in items.indices where items[index].request.device.serial == serial && [.pending, .running].contains(items[index].status) {
            if items[index].status == .running { operation?.cancel() }
            items[index].status = .failed
            items[index].message = "Headset disconnected. Reconnect and retry from the beginning. A hidden .questbridge partial copy may need removal."
        }
    }
    func retry(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), [.failed, .cancelled].contains(item.status) else { return }
        let old = item.request
        enqueue([TransferRequest(id: UUID(), batchID: UUID(), device: old.device, direction: old.direction, localURL: old.localURL, remotePath: old.remotePath)])
    }
    func waitUntilIdle() async { await worker?.value }
    func clearFinished() { items.removeAll { ![.pending, .running].contains($0.status) } }
    private func update(_ id: UUID, message: String, total: Int64?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .running else { return }
        items[index].message = message
        items[index].totalBytes = total
    }
    private func resolve(_ name: String, batch: UUID) async -> ConflictPolicy {
        if let policy = batchPolicies[batch] { return policy }
        guard !Task.isCancelled else { return .cancel }
        let decision = await conflictHandler?(name) ?? ConflictDecision(policy: .cancel, applyToBatch: false)
        if decision.applyToBatch { batchPolicies[batch] = decision.policy }
        return decision.policy
    }
    private func start() {
        guard worker == nil, let service else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            var failed = false
            while let index = items.firstIndex(where: { $0.status == .pending }) {
                let request = items[index].request
                items[index].status = .running
                items[index].startedAt = Date()
                let task = Task {
                    try await service.perform(request, conflict: { name in
                        await self.resolve(name, batch: request.batchID)
                    }, status: { message, total in await self.update(request.id, message: message, total: total) })
                }
                operation = task
                do {
                    let copied = try await task.value
                    if let current = items.firstIndex(where: { $0.id == request.id }), items[current].status == .running {
                        items[current].status = copied ? .completed : .skipped
                        items[current].message = copied ? "Verified and completed" : "Skipped — existing item preserved"
                    }
                } catch {
                    if let current = items.firstIndex(where: { $0.id == request.id }), items[current].status == .running {
                        items[current].status = error is CancellationError ? .cancelled : .failed
                        items[current].message = error is CancellationError ? "Cancelled. A partial copy may remain if the headset disconnected." : error.localizedDescription
                    }
                }
                failed = failed || items.contains { $0.id == request.id && $0.status == .failed }
                operation = nil
                changed?()
            }
            worker = nil
            batchPolicies.removeAll()
            finished?(failed)
        }
    }
}
