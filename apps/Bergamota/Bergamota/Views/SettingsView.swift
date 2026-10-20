import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Repository") {
                HStack {
                    TextField("Repo path", text: $s.repoPath)
                    Button("Choose...") { chooseRepo() }
                }
                Label(s.repoValid ? "Repo found" : "tools/mkpayload.py not found here",
                      systemImage: s.repoValid ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(s.repoValid ? .green : .orange)
                TextField("GitHub repo", text: $s.ghRepo)
            }
            Section("Phone") {
                TextField("Phone IP", text: $s.phoneIP)
                Text("USB Ethernet is found by MAC \(PhoneMonitor.usbMAC); SSH as root@IP (key only).").font(.caption).foregroundStyle(.secondary)
            }
            Section("Tools (leave empty to resolve via PATH, /opt/homebrew/bin, /usr/local/bin)") {
                toolRow("fastboot", $s.fastbootPath, s.fastboot)
                toolRow("adb", $s.adbPath, s.adb)
                toolRow("gh", $s.ghPath, s.gh)
                toolRow("python3", $s.pythonPath, s.python)
                toolRow("ssh", $s.sshPath, s.ssh)
            }
            Section("Live log") {
                Toggle("Always save the live log to logs/usb-<timestamp>.txt", isOn: $s.autoSaveLog)
            }
            Section("Remote control") {
                Toggle("Allow remote requests to start the queue", isOn: $s.allowRemoteStart)
                Text("Requests are JSON files dropped in ~/Library/Application Support/Bergamota/inbox (see scripts/bergamota). Status: status.json next to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Boot queue") {
                Toggle("If in OrangeFox, run `adb reboot bootloader` first", isOn: $s.rebootFromRecovery)
                Toggle("Notify when a boot is sent", isOn: $s.notifyOnBoot)
                Toggle("Notify when iOS comes up", isOn: $s.notifyOnIOS)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    @ViewBuilder private func toolRow(_ name: String, _ path: Binding<String>, _ resolved: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(name, text: path, prompt: Text("auto"))
            HStack(spacing: 4) {
                Image(systemName: resolved != nil ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(resolved != nil ? .green : .red)
                Text(resolved ?? "not found").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseRepo() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = model.settings.repoURL
        if p.runModal() == .OK, let u = p.url { model.settings.repoPath = u.path; model.build.rescan() }
    }
}
