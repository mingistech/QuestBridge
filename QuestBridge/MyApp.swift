import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: MainViewModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
@main struct QuestBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = MainViewModel()
    var body: some Scene {
        Window("QuestBridge", id: "main") {
            MainWindowView(model: model)
                .task { delegate.model = model; model.start() }
                .background(WindowPersistence())
        }
        .defaultSize(width: 1080, height: 740)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Folder…", action: model.makeFolder).keyboardShortcut("n").disabled(!model.connected)
                Button("Upload Files…") { model.chooseUploads() }.keyboardShortcut("o").disabled(!model.connected)
            }
            CommandMenu("Headset") {
                Button("Refresh", action: model.refresh).keyboardShortcut("r").disabled(!model.connected)
                Button("Back", action: model.back).keyboardShortcut("[", modifiers: .command).disabled(!model.canGoBack)
                Button("Forward", action: model.forward).keyboardShortcut("]", modifiers: .command).disabled(!model.canGoForward)
                Divider()
                Button("Upload Videos to Movies…") { model.chooseUploads(movies: true) }.disabled(!model.connected)
                Button("Download Selected…", action: model.downloadSelected).disabled(model.selection.isEmpty)
            }
        }
        Settings { SettingsView(model: model) }
    }
}
struct WindowPersistence: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PersistedWindowView() }
    func updateNSView(_ nsView: NSView, context: Context) { }
    private final class PersistedWindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.setFrameAutosaveName("QuestBridge.MainWindow")
        }
    }
}
