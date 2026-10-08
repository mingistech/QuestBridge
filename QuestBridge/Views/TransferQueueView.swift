import SwiftUI

struct TransferQueueView: View {
    @Bindable var queue: TransferQueue
    @State private var expanded = false
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if queue.active != nil { ProgressView().controlSize(.small) }
                else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(queue.active.map { "\($0.request.direction.rawValue) \($0.request.name)" } ?? (queue.items.isEmpty ? "Ready to transfer" : "Transfer queue finished"))
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    if let active = queue.active {
                        Text(active.message + (active.totalBytes.map { " · \(bytes($0)) total" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if let active = queue.active { Button { queue.cancel(active.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Cancel transfer") }
                Button { expanded.toggle() } label: { Label("\(queue.items.count) transfers", systemImage: expanded ? "chevron.down" : "chevron.up") }.buttonStyle(.plain).font(.caption)
            }
            if expanded {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(queue.items.reversed()) { item in
                            HStack(alignment: .top) {
                                Image(systemName: icon(item.status)).foregroundStyle(item.status == .failed ? Color.red : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.request.name).font(.subheadline).lineLimit(1)
                                    Text("\(item.status.rawValue) · \(item.message)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                if [.pending, .running].contains(item.status) { Button("Cancel") { queue.cancel(item.id) }.controlSize(.small) }
                                if [.failed, .cancelled].contains(item.status) { Button("Retry") { queue.retry(item.id) }.controlSize(.small) }
                            }
                        }
                    }
                }.frame(maxHeight: 170)
                HStack { Spacer(); Button("Clear Finished", action: queue.clearFinished).font(.caption) }
            }
        }.padding(.horizontal, 18).padding(.vertical, 13)
    }
    private func icon(_ status: TransferStatus) -> String {
        switch status {
        case .pending: "clock"
        case .running: "arrow.up.arrow.down"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .skipped: "arrow.turn.down.right"
        }
    }
}
struct ConflictView: View {
    let name: String
    let resolve: (ConflictPolicy, Bool) -> Void
    @State private var all = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("An item with this name already exists", systemImage: "doc.on.doc").font(.headline)
            Text(name).font(.title3).textSelection(.enabled)
            Text("Replace swaps the entire existing item, including all contents if it is a folder. Keep Both saves a separate copy.").foregroundStyle(.secondary)
            Toggle("Apply to all conflicts in this batch", isOn: $all)
            HStack {
                Button("Cancel Transfer") { resolve(.cancel, all) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { resolve(.skip, all) }
                Button("Replace", role: .destructive) { resolve(.replace, all) }
                Button("Keep Both") { resolve(.keepBoth, all) }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 520)
    }
}
