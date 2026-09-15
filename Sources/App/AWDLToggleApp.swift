import AppKit
import SwiftUI
import WidgetKit

final class SetupAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AWDLToggleApp: App {
    @NSApplicationDelegateAdaptor(SetupAppDelegate.self) private var delegate
    var body: some Scene {
        Window("AWDL Toggle", id: "status") {
            StatusView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

// The signed app also provides a small diagnostic CLI, sharing the exact same
// authenticated XPC client as the UI. It does not create a window in this mode.
@main
enum AWDLToggleEntry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, ["--status", "--on", "--off"].contains(command) else {
            AWDLToggleApp.main()
            return
        }
        Task {
            do {
                let status: AWDLStatus
                if command == "--status" { status = try await HelperClient.status() }
                else { status = try await HelperClient.setEnabled(command == "--on") }
                var result: [String: Any] = ["enabled": status.enabled, "monitoring": status.monitoring]
                result["interfaceUp"] = status.interfaceUp ?? NSNull() as Any
                if let issue = status.issue { result["issue"] = issue }
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                if command != "--status" { ControlCenter.shared.reloadControls(ofKind: "local.vitaly.AWDLToggle.Control") }
                exit(status.issue == nil && status.monitoring ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}

@MainActor
final class StatusModel: ObservableObject {
    @Published var status: AWDLStatus?
    @Published var error: String?
    @Published var busy = false

    func observe() async {
        var retrySeconds: UInt64 = 1
        while !Task.isCancelled {
            do {
                for try await update in HelperObservation.stream() {
                    guard !Task.isCancelled else { return }
                    status = update
                    error = update.issue
                    retrySeconds = 1
                }
            } catch {
                guard !Task.isCancelled else { return }
                status = nil
                self.error = "Cannot reach the AWDL helper. Reconnecting automatically…"
            }
            do { try await Task.sleep(nanoseconds: retrySeconds * 1_000_000_000) }
            catch { return }
            retrySeconds = min(retrySeconds * 2, 8)
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await HelperClient.setEnabled(enabled)
            error = result.issue
        } catch {
            self.error = error.localizedDescription
            // The ordered observation stream remains the source of displayed state.
        }
        ControlCenter.shared.reloadControls(ofKind: "local.vitaly.AWDLToggle.Control")
    }
}

struct StatusView: View {
    @StateObject private var model = StatusModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AWDL Toggle").font(.title2.bold())
                    Text("A manual switch for Apple Wireless Direct Link.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if model.status != nil {
                        Toggle("AWDL", isOn: Binding(
                            get: { model.status?.enabled ?? false },
                            set: { enabled in Task { await model.setEnabled(enabled) } }
                        ))
                        .toggleStyle(.switch)
                        .disabled(model.busy)
                    } else {
                        LabeledContent("AWDL", value: "Unavailable")
                    }
                    Text(model.status?.summary ?? "Helper unavailable")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(8)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Add it to Control Center").font(.headline)
                Text("Open Control Center → Edit Controls, search for AWDL, and add the small circular control.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("To add it to the menu bar, drag AWDL from the controls gallery to the menu bar while editing.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("On allows AWDL. Off keeps it down. Your choice stays active when this app is closed and after restarting your Mac.")
                Text("AirDrop and features that rely on AWDL may be unavailable while it is off.")
                    .foregroundStyle(.secondary)
            }.font(.callout)
            Divider()
            HStack {
                Spacer()
                Button("Repair…") { openResource("AWDL-Toggle-Repair", extension: "pkg") }
                Button("Uninstall…") { openResource("AWDL-Toggle-Uninstall", extension: "pkg") }
            }
            Text("Repair and uninstall open macOS Installer and require administrator approval. Uninstall restores AWDL before removing the helper.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 460)
        .task { await model.observe() }
    }

    private func openResource(_ name: String, extension suffix: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: suffix) {
            NSWorkspace.shared.open(url)
        } else {
            model.error = "This is a development build. Install the packaged version to enable repair and uninstall."
        }
    }
}
