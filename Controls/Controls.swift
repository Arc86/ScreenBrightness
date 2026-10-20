import AppIntents
import SwiftUI
import WidgetKit

/// Controls for Control Center and the menu bar. Each one runs a shared intent, which hands
/// the command to the app.
@main
struct ScreenBrightnessControls: WidgetBundle {
    var body: some Widget {
        BrighterControl()
        DimmerControl()
        PresetControl()
        TurnOffMonitorControl()
    }
}

struct BrighterControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.jespermol.ScreenBrightness.brighter") {
            ControlWidgetButton(action: StepBrightnessIntent(direction: .brighter)) {
                Label("Brighter", systemImage: "sun.max.fill")
            }
        }
        .displayName("Monitor Brighter")
        .description("Makes the external monitor one step brighter.")
    }
}

struct DimmerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.jespermol.ScreenBrightness.dimmer") {
            ControlWidgetButton(action: StepBrightnessIntent(direction: .dimmer)) {
                Label("Dimmer", systemImage: "sun.min.fill")
            }
        }
        .displayName("Monitor Dimmer")
        .description("Makes the external monitor one step dimmer.")
    }
}

struct PresetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.jespermol.ScreenBrightness.preset", intent: PresetControlConfiguration.self) { configuration in
            ControlWidgetButton(action: ApplyPresetIntent(preset: configuration.preset ?? PresetEntity.placeholder)) {
                Label(configuration.preset?.name ?? "Preset", systemImage: "square.grid.2x2.fill")
            }
        }
        .displayName("Brightness Preset")
        .description("Applies one of your brightness presets.")
        .promptsForUserConfiguration()
    }
}

struct PresetControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Brightness Preset"
    static let isDiscoverable = false

    @Parameter(title: "Preset")
    var preset: PresetEntity?

    func perform() async throws -> some IntentResult {
        .result()
    }
}

extension PresetEntity {
    /// Stands in until a preset is picked; applying it does nothing, since no preset has its ID.
    static var placeholder: PresetEntity {
        PresetEntity(Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "Preset", level: 50))
    }
}

struct TurnOffMonitorControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.jespermol.ScreenBrightness.turnOff") {
            ControlWidgetButton(action: TurnOffMonitorIntent()) {
                Label("Turn Off Monitor", systemImage: "moon.zzz.fill")
            }
        }
        .displayName("Turn Off Monitor")
        .description("Puts the displays to sleep. Any key or mouse movement turns them back on.")
    }
}
