import AppIntents
import SwiftUI
import WidgetKit

@main
struct AWDLToggleWidgets: WidgetBundle {
    var body: some Widget { AWDLToggle() }
}

struct AWDLToggle: ControlWidget {
    static let kind = "local.vitaly.AWDLToggle.Control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { enabled in
            ControlWidgetToggle("AWDL", isOn: enabled, action: SetAWDLEnabledIntent()) { isOn in
                Label(isOn ? "On" : "Off", systemImage: "antenna.radiowaves.left.and.right")
            }
            .tint(.blue)
        }
        .displayName("AWDL")
        .description("Allow AWDL for AirDrop and Continuity, or continuously keep it off.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }
        func currentValue() async throws -> Bool {
            let status = try await HelperClient.status()
            if let issue = status.issue { throw HelperFailure.message(issue) }
            guard status.monitoring else { throw HelperFailure.message("The AWDL monitor is unavailable.") }
            guard status.interfaceUp != nil else { throw HelperFailure.message("The AWDL interface is not available yet.") }
            return status.enabled
        }
    }
}

struct SetAWDLEnabledIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set AWDL"
    static var description = IntentDescription("Allow AWDL, or keep its interface down until you turn it on again.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "AWDL enabled")
    var value: Bool

    func perform() async throws -> some IntentResult {
        let status = try await HelperClient.setEnabled(value)
        if let issue = status.issue { throw HelperFailure.message(issue) }
        guard status.enabled == value, status.monitoring else {
            throw HelperFailure.message("AWDL could not be changed. Open AWDL Toggle to check the helper.")
        }
        guard status.interfaceUp != nil else {
            throw HelperFailure.message("Your choice is saved. Waiting for the AWDL interface to become available.")
        }
        return .result()
    }
}
