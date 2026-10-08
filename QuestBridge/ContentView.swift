import SwiftUI

struct MainWindowView: View {
    @Bindable var model: MainViewModel
    @State private var sidebar: NavigationSplitViewVisibility = .all
    @State private var dropTarget = false
    private let favorites: [(String, String, String)] = [("Movies", "Movies", "film"), ("Downloads", "Download", "arrow.down.circle"), ("Pictures", "Pictures", "photo"), ("DCIM", "DCIM", "camera")]
    var body: some View {
        NavigationSplitView(columnVisibility: $sidebar) {
            List {
                Section("Favorites") {
                    ForEach(favorites, id: \.0) { item in
                        sidebarItem(item.0, component: item.1, icon: item.2)
                    }
                }
                Section("Device") { sidebarItem("Internal Storage", component: "", icon: "internaldrive") }
                Section {
                    Button { model.showOnboarding = true } label: { Label("Connection Guide", systemImage: "questionmark.circle") }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 175, ideal: 205, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("QuestBridge", systemImage: "vision.pro").font(.headline)
                    Text("Your videos. On your Quest.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        } detail: {
            VStack(spacing: 0) {
                deviceHeader
                Divider()
                if model.connected { browser }
                else { connectionState }
                Divider()
                dropZone
                Divider()
                TransferQueueView(queue: model.queue)
            }
            .background(.background)
        }
        .frame(minWidth: 840, minHeight: 580)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: model.back) { Label("Back", systemImage: "chevron.left") }.disabled(!model.canGoBack)
                Button(action: model.forward) { Label("Forward", systemImage: "chevron.right") }.disabled(!model.canGoForward)
                Button(action: model.up) { Label("Enclosing Folder", systemImage: "arrow.up") }.disabled(!model.connected || model.currentPath == model.context?.root)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.chooseUploads(movies: true) } label: { Label("Upload Videos", systemImage: "arrow.up.doc") }.disabled(!model.connected)
                Button(action: model.refresh) { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!model.connected)
                Menu {
                    Button("New Folder…", systemImage: "folder.badge.plus", action: model.makeFolder)
                    Button("Upload to Current Folder…", systemImage: "arrow.up", action: { model.chooseUploads() })
                    Button("Upload to Default Folder…", action: model.uploadDefault)
                    Button("Download Selected…", systemImage: "arrow.down", action: model.downloadSelected).disabled(model.selection.isEmpty)
                    Button("Rename…", action: model.renameSelected).disabled(model.selection.count != 1)
                    Divider()
                    Button("Delete Selected…", systemImage: "trash", role: .destructive, action: model.deleteSelected).disabled(model.selection.isEmpty)
                } label: { Label("File Actions", systemImage: "ellipsis.circle") }.disabled(!model.connected)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model) }
        .sheet(item: $model.conflict) { prompt in ConflictView(name: prompt.name, resolve: model.resolveConflict).interactiveDismissDisabled() }
        .alert("QuestBridge", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private func sidebarItem(_ title: String, component: String, icon: String) -> some View {
        let destination = model.context.map { $0.root + (component.isEmpty ? "" : "/" + component) }
        return Button { if let destination { model.navigate(destination) } } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .foregroundStyle(destination == model.currentPath ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain).disabled(!model.connected)
        .dropDestination(for: URL.self) { urls, _ in
            guard let destination else { return false }; model.upload(urls, destination: destination); return true
        }
    }
    private var deviceHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "vision.pro").font(.system(size: 30)).foregroundStyle(.tint)
                .frame(width: 54, height: 54).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle().fill(model.connected ? .green : .orange).frame(width: 7, height: 7)
                    Text(model.selectedDevice?.displayName ?? "No headset connected").font(.headline)
                    if model.connected { Text("Connected").font(.caption).foregroundStyle(.secondary) }
                }
                if let storage = model.storage {
                    Text("\(bytes(storage.available)) available of \(bytes(storage.total)) usable storage").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(storage.total - storage.available), total: Double(storage.total)).frame(maxWidth: 280).tint(.accentColor)
                } else { Text(model.connected ? "Storage information unavailable" : "USB connection · ADB").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if model.devices.count > 1 {
                Picker("Headset", selection: Binding(get: { model.selectedSerial }, set: { model.selectDevice($0) })) {
                    ForEach(model.devices) { device in Text(device.displayName).tag(device.id) }
                }.labelsHidden().frame(maxWidth: 170).disabled(model.queue.hasWork)
            }
        }.padding(20)
    }
    private var connectionState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: model.selectedDevice?.state == .unauthorized ? "lock.shield" : "cable.connector").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(model.selectedDevice?.state == .unauthorized ? "Authorize your Mac" : "Ready when you connect").font(.title2.bold())
            Text(model.statusMessage).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 400)
            HStack {
                Button("Connection Guide") { model.showOnboarding = true }
                Button("Retry", action: model.reconnect).buttonStyle(.borderedProminent)
                if model.resolvedADBPath.isEmpty { SettingsLink { Text("Select ADB…") } }
            }
            Spacer()
            Text("ADB file transfers work independently of MTP.\nUSB debugging authorization is required on first connection.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.bottom, 25)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let context = model.context {
                            Button { model.navigate(context.root) } label: { Image(systemName: "internaldrive") }
                            let parts = model.currentPath.dropFirst(context.root.count).split(separator: "/").map(String.init)
                            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                Button(part) { model.navigate(context.root + "/" + parts.prefix(index + 1).joined(separator: "/")) }
                            }
                        }
                    }.buttonStyle(.plain).font(.subheadline)
                }
                if model.isLoading { ProgressView().controlSize(.small) }
                Menu {
                    Picker("Sort by", selection: $model.sort) { ForEach(BrowserSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("Ascending", isOn: $model.ascending)
                } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).frame(width: 24).help("Sort files")
                TextField("Search this folder", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 160)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            FileBrowserView(model: model)
            HStack {
                Text("\(model.visibleFiles.count) items")
                if !model.selection.isEmpty { Text("· \(model.selection.count) selected") }
                Spacer()
                Text("Shared storage").foregroundStyle(.tertiary)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 8)
        }
    }
    private var dropZone: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.circle").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Drop files here for Movies").font(.subheadline.weight(.medium))
                Text("Videos and folders · Original files, no conversion").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose Files…") { model.chooseUploads(movies: true) }.disabled(!model.connected)
        }
        .padding(16).background(dropTarget ? Color.accentColor.opacity(0.12) : Color.accentColor.opacity(0.035))
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(5) } }
        .dropDestination(for: URL.self) { urls, _ in guard model.connected else { return false }; model.upload(urls); return true } isTargeted: { dropTarget = $0 }
    }
}
