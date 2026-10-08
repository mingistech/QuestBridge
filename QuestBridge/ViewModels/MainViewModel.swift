import AppKit
import SwiftUI
import UserNotifications
import OSLog

@MainActor @Observable final class Preferences {
    var adbPath = UserDefaults.standard.string(forKey: "adbPath") ?? "" { didSet { save("adbPath", adbPath) } }
    var uploadFolder = UserDefaults.standard.string(forKey: "uploadFolder") ?? "Movies" { didSet { save("uploadFolder", uploadFolder) } }
    var downloadFolder = UserDefaults.standard.string(forKey: "downloadFolder") ?? "" { didSet { save("downloadFolder", downloadFolder) } }
    var rememberFolder = UserDefaults.standard.object(forKey: "rememberFolder") as? Bool ?? true { didSet { save("rememberFolder", rememberFolder) } }
    var notifications = UserDefaults.standard.bool(forKey: "notifications") { didSet { save("notifications", notifications) } }
    var conflictPolicy = UserDefaults.standard.string(forKey: "conflictPolicy") ?? ConflictPolicy.ask.rawValue { didSet { save("conflictPolicy", conflictPolicy) } }
    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
}
struct ConflictPrompt: Identifiable {
    let id = UUID()
    let name: String
    let continuation: CheckedContinuation<ConflictDecision, Never>
}
enum BrowserSort: String, CaseIterable { case name = "Name", size = "Size", date = "Modified", type = "Kind" }

@MainActor @Observable final class MainViewModel {
    let preferences = Preferences()
    let queue = TransferQueue()
    var devices: [QuestDevice] = []
    var selectedSerial = UserDefaults.standard.string(forKey: "selectedDevice") ?? ""
    var context: DeviceContext?
    var files: [RemoteFile] = []
    var selection: Set<String> = []
    var currentPath = ""
    var storage: StorageInfo?
    var isLoading = false
    var statusMessage = "Connect your Quest headset using a USB-C data cable."
    var errorMessage: String?
    var diagnostics = ""
    var adbVersion = "Not configured"
    var resolvedADBPath = ""
    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarded")
    var conflict: ConflictPrompt?
    var sort: BrowserSort = .name
    var ascending = true
    var search = ""
    private var fs: (any RemoteFileSystem)?
    private var monitor: Task<Void, Never>?
    private var listing: Task<Void, Never>?
    private var discovering = false
    private var generation = UUID()
    private var listingID = UUID()
    private var history: [String] = []
    private var historyIndex = -1
    var connected: Bool { context != nil }
    var selectedDevice: QuestDevice? { devices.first { $0.id == selectedSerial } }
    var selectedFiles: [RemoteFile] { files.filter { selection.contains($0.id) } }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }
    var visibleFiles: [RemoteFile] {
        files.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let comparison: Bool
            switch sort {
            case .name: comparison = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: comparison = a.size == b.size ? a.name < b.name : (a.size ?? -1) < (b.size ?? -1)
            case .date: comparison = a.modificationDate == b.modificationDate ? a.name < b.name : (a.modificationDate ?? .distantPast) < (b.modificationDate ?? .distantPast)
            case .type: comparison = a.typeName == b.typeName ? a.name < b.name : a.typeName < b.typeName
            }
            return ascending ? comparison : (!comparison && a != b)
        }
    }
    init() {
        queue.conflictHandler = { [weak self] name in
            guard let self else { return ConflictDecision(policy: .cancel, applyToBatch: false) }
            let preference = ConflictPolicy(rawValue: preferences.conflictPolicy) ?? .ask
            if preference == .skip || preference == .keepBoth { return ConflictDecision(policy: preference, applyToBatch: true) }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume(returning: ConflictDecision(policy: .cancel, applyToBatch: false)) }
                    else { conflict = ConflictPrompt(name: name, continuation: continuation) }
                }
            } onCancel: { Task { @MainActor [weak self] in self?.resolveConflict(.cancel, all: false) } }
        }
        queue.changed = { [weak self] in self?.refresh() }
        queue.finished = { [weak self] failed in
            self?.notify(title: failed ? "Transfer needs attention" : "Transfer queue finished", body: failed ? "Open QuestBridge to review the failed transfers." : "Review your completed transfers in QuestBridge.")
        }
    }
    func start() {
        guard monitor == nil else { return }
        let token = UUID(); generation = token
        do {
            let executable = try ADBResolver.resolve(custom: preferences.adbPath)
            resolvedADBPath = executable.path
            let adb = ADBProcessRunner(executable: executable)
            let filesystem = RemoteFileSystemService(adb: adb)
            fs = filesystem
            queue.configure(TransferService(adb: adb, fs: filesystem))
            let discovery = DeviceDiscoveryService(adb: adb)
            monitor = Task { [weak self] in
                do {
                    let version = try await adb.execute(arguments: ["version"])
                    self?.adbVersion = version.text.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch { self?.record(error, show: false) }
                await discovery.monitor { [weak self] in await self?.discover(discovery, token: token) }
            }
        } catch { record(error, show: false); statusMessage = error.localizedDescription }
    }
    func reconnect() {
        guard !queue.hasWork else { errorMessage = "Wait for transfers to finish, or cancel them before changing the ADB connection."; return }
        monitor?.cancel(); monitor = nil
        listing?.cancel(); context = nil; files = []; storage = nil
        discovering = false
        start()
    }
    private func discover(_ discovery: DeviceDiscoveryService, token: UUID) async {
        guard token == generation, !discovering else { return }
        discovering = true
        defer { if token == generation { discovering = false } }
        do {
            let found = try await discovery.discover()
            guard token == generation, !Task.isCancelled else { return }
            devices = found
            if let context, !found.contains(where: { $0.id == context.serial && $0.state == .device && $0.isQuest }) {
                disconnect()
            }
            if !found.contains(where: { $0.id == selectedSerial }) {
                selectedSerial = found.first(where: { $0.isQuest && $0.state == .device })?.id ?? found.first?.id ?? ""
            }
            await updateConnection(token: token)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            disconnect(); record(error, show: false); statusMessage = error.localizedDescription
        }
    }
    func selectDevice(_ serial: String) {
        guard !queue.hasWork else { return }
        selectedSerial = serial
        UserDefaults.standard.set(serial, forKey: "selectedDevice")
        disconnect()
        let token = generation
        Task { await updateConnection(token: token) }
    }
    private func updateConnection(token: UUID) async {
        guard let device = selectedDevice else { disconnect(); statusMessage = "Connect your Quest headset using a USB-C data cable."; return }
        guard device.state == .device else {
            disconnect()
            statusMessage = device.state == .unauthorized ? "Put on your headset and approve USB debugging. Select “Always allow from this computer” if offered." : "Your device is offline. Unlock it and reconnect the USB cable."
            return
        }
        guard device.isQuest else { disconnect(); statusMessage = "This Android device has not been identified as a Meta Quest. Connect a Quest headset to manage its files."; return }
        if context?.serial == device.id { return }
        guard let fs else { return }
        do {
            let newContext = try await fs.connect(serial: device.id)
            guard token == generation, selectedSerial == device.id, !Task.isCancelled else { return }
            context = newContext; history = []; historyIndex = -1; currentPath = ""
            statusMessage = "\(device.displayName) is ready for file transfers."
            UserDefaults.standard.set(device.id, forKey: "selectedDevice")
            let remembered = preferences.rememberFolder ? UserDefaults.standard.string(forKey: "lastPath.\(device.id)") : nil
            let initial = remembered.flatMap { try? RemotePath.normalize($0, root: newContext.root) } ?? newContext.root + "/Movies"
            navigate(initial)
        } catch { record(error, show: false); statusMessage = error.localizedDescription }
    }
    private func disconnect() {
        if let context {
            queue.failDevice(context.serial)
            if queue.items.contains(where: { $0.status == .failed }) { notify(title: "Quest disconnected", body: "Reconnect your headset and retry interrupted transfers.") }
        }
        context = nil; files = []; selection = []; storage = nil; listing?.cancel(); isLoading = false
    }
    func navigate(_ path: String, recordHistory: Bool = true) {
        guard let context, let clean = try? RemotePath.normalize(path, root: context.root) else { return }
        if recordHistory && currentPath != clean {
            history = Array(history.prefix(historyIndex + 1)); history.append(clean); historyIndex = history.count - 1
        }
        currentPath = clean; selection = []; search = ""
        if preferences.rememberFolder { UserDefaults.standard.set(clean, forKey: "lastPath.\(context.serial)") }
        refresh()
    }
    func back() { guard canGoBack else { return }; historyIndex -= 1; navigate(history[historyIndex], recordHistory: false) }
    func forward() { guard canGoForward else { return }; historyIndex += 1; navigate(history[historyIndex], recordHistory: false) }
    func up() { if let context { navigate(RemotePath.parent(currentPath, root: context.root)) } }
    func refresh() {
        listing?.cancel()
        guard let context, let fs else { return }
        let path = currentPath
        let token = UUID(); listingID = token
        isLoading = true
        listing = Task {
            defer { if listingID == token { isLoading = false } }
            do {
                let result = try await fs.listDirectory(path, device: context)
                guard !Task.isCancelled, listingID == token, self.context == context, currentPath == path else { return }
                files = result; selection.formIntersection(Set(result.map(\.id)))
                let capacity = try? await fs.storage(device: context)
                if !Task.isCancelled, listingID == token, self.context == context { storage = capacity }
            } catch { if !Task.isCancelled { files = []; record(error) } }
        }
    }
    func makeFolder() {
        guard let context, let fs, let name = askName(title: "New folder", initial: "Untitled Folder") else { return }
        do {
            let path = try RemotePath.child(name, of: currentPath, root: context.root)
            guard !files.contains(where: { RemotePath.folded($0.name) == RemotePath.folded(name) }) else { throw BridgeError(message: "A file or folder with this name already exists.") }
            Task { do { try await fs.createDirectory(path, device: context); refresh() } catch { record(error) } }
        } catch { record(error) }
    }
    func renameSelected() {
        guard let context, let fs, selectedFiles.count == 1, let file = selectedFiles.first,
              let name = askName(title: "Rename item", initial: file.name), name != file.name else { return }
        do {
            let path = try RemotePath.child(name, of: currentPath, root: context.root)
            guard !files.contains(where: { RemotePath.folded($0.name) == RemotePath.folded(name) }) else { throw BridgeError(message: "That name is already in use. Choose a different name.") }
            Task { do { try await fs.rename(from: file.path, to: path, device: context); refresh() } catch { record(error) } }
        } catch { record(error) }
    }
    func deleteSelected() {
        guard let context, let fs, !selectedFiles.isEmpty else { return }
        let targets = selectedFiles
        let alert = NSAlert()
        alert.messageText = "Delete \(targets.count) selected item\(targets.count == 1 ? "" : "s")?"
        alert.informativeText = "This permanently deletes these items from your headset, including all contents of selected folders. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task {
            do { for file in targets { try await fs.delete(file.path, device: context) }; refresh() }
            catch { record(error); refresh() }
        }
    }
    private func askName(title: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    func chooseUploads(movies: Bool = false) {
        guard connected else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = movies ? "Choose videos or folders to send to Movies. Files are copied without conversion." : "Choose files or folders to upload to the current folder."
        panel.prompt = "Upload"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self, let context = self.context else { return }
                self.upload(panel.urls, destination: movies ? context.root + "/Movies" : self.currentPath)
            }
        }
    }
    func upload(_ urls: [URL], destination: String? = nil) {
        guard let context, !urls.isEmpty else { return }
        let path = destination ?? context.root + "/Movies"
        let batch = UUID()
        queue.enqueue(urls.filter(\.isFileURL).map { TransferRequest(id: UUID(), batchID: batch, device: context, direction: .upload, localURL: $0, remotePath: path) })
    }
    func uploadDefault() {
        guard let context else { return }
        let folder = preferences.uploadFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let destination = context.root + "/" + folder
        guard (try? RemotePath.normalize(destination, root: context.root)) != nil else { errorMessage = "Choose a valid shared-storage upload folder in Settings."; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in if response == .OK { Task { @MainActor in self?.upload(panel.urls, destination: destination) } } }
    }
    func downloadSelected() {
        guard let context, !selectedFiles.isEmpty else { return }
        let selected = selectedFiles
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Download Here"
        if !preferences.downloadFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: preferences.downloadFolder) }
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.preferences.downloadFolder = folder.path
                let batch = UUID()
                self.queue.enqueue(selected.map { TransferRequest(id: UUID(), batchID: batch, device: context, direction: .download, localURL: folder, remotePath: $0.path) })
            }
        }
    }
    func resolveConflict(_ policy: ConflictPolicy, all: Bool) {
        let prompt = conflict; conflict = nil
        prompt?.continuation.resume(returning: ConflictDecision(policy: policy, applyToBatch: all))
    }
    func record(_ error: Error, show: Bool = true) {
        let detail = (error as? BridgeError)?.detail ?? String(describing: error)
        diagnostics = "\(Date().formatted())\n\(error.localizedDescription)\n\(detail)"
        Logger(subsystem: "QuestBridge", category: "Application").error("\(detail, privacy: .private)")
        if show { errorMessage = error.localizedDescription }
    }
    func enableNotifications() async {
        do { preferences.notifications = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        catch { record(error) }
    }
    private func notify(title: String, body: String) {
        guard preferences.notifications else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
    func shutdown() async {
        resolveConflict(.cancel, all: false)
        listing?.cancel(); monitor?.cancel(); queue.cancelAll()
        await ADBProcessRunner.shutdownClients()
        await queue.waitUntilIdle()
        await monitor?.value
    }
}
