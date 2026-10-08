import SwiftUI

struct FileBrowserView: View {
    @Bindable var model: MainViewModel
    @FocusState private var browserFocused: Bool
    var body: some View {
        Table(model.visibleFiles, selection: $model.selection) {
            TableColumn("Name") { file in
                HStack(spacing: 9) {
                    Image(systemName: file.icon).foregroundStyle(file.isDirectory ? Color.accentColor : .secondary).frame(width: 18)
                    Text(file.name).lineLimit(1)
                }
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dropDestination(for: URL.self) { urls, _ in
                    guard file.isDirectory else { return false }; model.upload(urls, destination: file.path); return true
                }
            }.width(min: 190, ideal: 300)
            TableColumn("Size") { file in Text(file.isDirectory ? "—" : file.size.map(bytes) ?? "Unknown").foregroundStyle(.secondary).monospacedDigit() }.width(min: 65, ideal: 85, max: 100)
            TableColumn("Modified") { file in Text(file.modificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown").foregroundStyle(.secondary) }.width(min: 120, ideal: 150)
            TableColumn("Kind") { file in Text(file.typeName).foregroundStyle(.secondary) }.width(min: 55, ideal: 75, max: 100)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Open Folder") { open(ids) }.disabled(ids.count != 1 || !model.files.contains(where: { ids.contains($0.id) && $0.isDirectory }))
            Button("Download…") { model.selection = ids; model.downloadSelected() }.disabled(ids.isEmpty)
            Button("Rename…") { model.selection = ids; model.renameSelected() }.disabled(ids.count != 1)
            Divider()
            Button("Delete \(ids.count) Item\(ids.count == 1 ? "" : "s")…", role: .destructive) { model.selection = ids; model.deleteSelected() }.disabled(ids.isEmpty)
        } primaryAction: { ids in open(ids) }
        .focused($browserFocused)
        .onKeyPress(.return) { guard browserFocused, model.selection.count == 1 else { return .ignored }; model.renameSelected(); return .handled }
        .onKeyPress(keys: [.delete], phases: .down) { key in
            guard browserFocused, key.modifiers.contains(.command), !model.selection.isEmpty else { return .ignored }
            model.deleteSelected(); return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "a"), phases: .down) { key in
            guard browserFocused, key.modifiers.contains(.command) else { return .ignored }
            model.selection = Set(model.visibleFiles.map(\.id)); return .handled
        }
        .overlay {
            if model.files.isEmpty && !model.isLoading {
                ContentUnavailableView("This folder is empty", systemImage: "folder", description: Text("Upload to this folder using the File Actions menu,\nor drop files below to send them to Movies."))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.upload(urls); return model.connected }
    }
    private func open(_ ids: Set<String>) {
        if ids.count == 1, let file = model.files.first(where: { ids.contains($0.id) }), file.isDirectory { model.navigate(file.path) }
    }
}
