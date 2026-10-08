import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var model: MainViewModel
    var body: some View {
        @Bindable var preferences = model.preferences
        TabView {
            Form {
                Section("File browsing") {
                    TextField("Default upload folder", text: $preferences.uploadFolder)
                    Text("Relative to shared storage, for example Movies or Movies/VR. Quick Upload and empty-area drops always use Movies. The folder must already exist.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Remember the last remote folder", isOn: $preferences.rememberFolder)
                    LabeledContent("Deletion", value: "Always requires confirmation")
                }
                Section("Notifications") {
                    Toggle("Notify when the queue finishes", isOn: Binding(get: { preferences.notifications }, set: { value in
                        if value { Task { await model.enableNotifications() } } else { preferences.notifications = false }
                    }))
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Section("Android Debug Bridge") {
                    TextField("Custom executable", text: $preferences.adbPath)
                    HStack {
                        Button("Choose ADB…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = false
                            panel.message = "Choose the adb executable from official Android Platform Tools."
                            if panel.runModal() == .OK, let url = panel.url { preferences.adbPath = url.path; model.reconnect() }
                        }
                        Button("Apply / Retry", action: model.reconnect).disabled(model.queue.hasWork)
                    }
                    Text("Resolution order: bundled ADB, custom location, existing Android SDK or Homebrew installation.").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Using", value: model.resolvedADBPath.isEmpty ? "No executable found" : model.resolvedADBPath).textSelection(.enabled)
                    Text(model.adbVersion).font(.caption.monospaced()).textSelection(.enabled)
                    Link("Get official Android Platform Tools", destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!)
                }
                Section("Connection") {
                    LabeledContent("Selected device", value: model.selectedDevice?.displayName ?? "None")
                    Button("Open Connection Guide") { model.showOnboarding = true; NSApp.activate(ignoringOtherApps: true) }
                    Text("Use a data-capable USB cable. Unlock the headset and authorize USB debugging. QuestBridge does not need MTP and never resets the shared ADB server.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Diagnostic details") {
                    ScrollView { Text(model.diagnostics.isEmpty ? "No errors recorded." : model.diagnostics).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90)
                }
            }.formStyle(.grouped).tabItem { Label("Connection", systemImage: "cable.connector") }
            Form {
                Section("Downloads") {
                    LabeledContent("Destination", value: preferences.downloadFolder.isEmpty ? "Choose when downloading" : preferences.downloadFolder)
                    Button("Choose Default Folder…") {
                        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { preferences.downloadFolder = url.path }
                    }
                }
                Section("Existing files") {
                    Picker("On name conflict", selection: $preferences.conflictPolicy) {
                        ForEach([ConflictPolicy.ask, .skip, .keepBoth], id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    Text("Replace is offered in the conflict dialog and always requires an explicit choice.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Transfer behavior") {
                    Text("Transfers run one at a time. New copies are staged and checked by file size before receiving their final names. Replacements need enough space for the full new copy.")
                    Text("Interrupted transfers restart from the beginning. Progress is indeterminate when ADB does not supply reliable measurements.").foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
        }.padding(12).frame(width: 590, height: 570)
    }
}
struct OnboardingView: View {
    @Bindable var model: MainViewModel
    @Environment(\.dismiss) private var dismiss
    private let steps = [
        ("Enable Developer Mode", "Use Meta’s developer setup and enable Developer Mode for your headset in the Meta Horizon mobile app."),
        ("Connect with a USB-C data cable", "A charging-only cable cannot transfer files. Keep the headset awake and unlocked."),
        ("Approve USB debugging in your headset", "Put on your Quest and approve the prompt. Select “Always allow from this computer” if offered."),
        ("Return to QuestBridge", "Your headset will appear automatically. Send videos to Movies and open that folder in HereSphere.")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "vision.pro").font(.system(size: 38)).foregroundStyle(.tint)
                VStack(alignment: .leading) { Text("Meet your headset’s new bridge.").font(.title2.bold()); Text("One setup. Simple USB transfers.").foregroundStyle(.secondary) }
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 14) {
                    Text("\(index + 1)").font(.headline).frame(width: 28, height: 28).background(.tint.opacity(0.1), in: Circle()).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) { Text(step.0).font(.headline); Text(step.1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Text("USB debugging authorization is required. It can be revoked or requested again by the headset. A separate MTP file-access approval is not needed for ADB transfers.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.connected { Label("Headset connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Button("Get Started") { UserDefaults.standard.set(true, forKey: "onboarded"); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(32).frame(width: 570)
    }
}
