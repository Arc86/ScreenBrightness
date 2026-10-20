import AppIntents
import AppKit

// Intents used by both the app (Shortcuts, Siri) and its Control Center controls. In the app they
// act directly; in the controls extension they ask the running app, or launch it, via `ControlRelay`.

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Brightness Preset"
    static let description = IntentDescription("Applies one of your brightness presets to the external monitor.")

    @Parameter(title: "Preset")
    var preset: PresetEntity

    init() {}

    init(preset: PresetEntity) {
        self.preset = preset
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$preset)")
    }

    func perform() async throws -> some IntentResult {
        await ControlRelay.send(.applyPreset(preset.id))
        return .result()
    }
}

struct StepBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Step Monitor Brightness"
    static let description = IntentDescription("Makes the external monitor one step brighter or dimmer, like the brightness keys.")
    static let isDiscoverable = false

    @Parameter(title: "Direction")
    var direction: StepDirection

    init() {}

    init(direction: StepDirection) {
        self.direction = direction
    }

    func perform() async throws -> some IntentResult {
        await ControlRelay.send(.step(direction == .brighter ? .up : .down))
        return .result()
    }
}

enum StepDirection: String, AppEnum {
    case brighter, dimmer

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Direction"
    static let caseDisplayRepresentations: [StepDirection: DisplayRepresentation] = [
        .brighter: "Brighter",
        .dimmer: "Dimmer",
    ]
}

struct TurnOffMonitorIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Monitor"
    static let description = IntentDescription(
        "Puts the displays to sleep, which turns the monitor's panel off. Any key or mouse movement turns it back on.")

    func perform() async throws -> some IntentResult {
        await ControlRelay.send(.turnOffMonitor)
        return .result()
    }
}

struct PresetEntity: AppEntity {
    let id: UUID
    let name: String
    let level: Int

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
        level = preset.level
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Brightness Preset"
    static let defaultQuery = PresetQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(level)%")
    }
}

/// Reads presets from the shared store, which the app keeps current, so it works in either process.
struct PresetQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        Preset.load().filter { identifiers.contains($0.id) }.map(PresetEntity.init)
    }

    func suggestedEntities() async throws -> [PresetEntity] {
        Preset.load().map(PresetEntity.init)
    }
}

enum ControlRelay {
    static let appBundleIdentifier = "com.jespermol.ScreenBrightness"

    @MainActor
    static func send(_ command: SharedStore.Command) async {
        #if CONTROLS_EXTENSION
        if NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier).isEmpty {
            // ScreenBrightness.app/Contents/PlugIns/Controls.appex
            let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = ["-command", command.rawValue]
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } else {
            DistributedNotificationCenter.default().postNotificationName(
                SharedStore.commandNotification, object: command.rawValue, userInfo: nil, deliverImmediately: true)
        }
        #else
        BrightnessController.shared.perform(command)
        #endif
    }
}
