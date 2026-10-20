import AppIntents

struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Monitor Brightness"
    static let description = IntentDescription(
        "Sets the external monitor's brightness. Values below 0 dim further in software when extra dimming is on.")

    @Parameter(title: "Brightness", default: 50, inclusiveRange: (-50, 100))
    var level: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set monitor brightness to \(\.$level)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        BrightnessController.shared.setLevel(Double(level), animated: true)
        return .result()
    }
}

struct AdjustBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Adjust Monitor Brightness"
    static let description = IntentDescription("Makes the external monitor brighter or dimmer by an amount.")

    @Parameter(title: "Change", default: 10, inclusiveRange: (-150, 150))
    var amount: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Change monitor brightness by \(\.$amount)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let controller = BrightnessController.shared
        if controller.status == .connecting { await controller.refresh() }
        controller.setLevel(controller.level + Double(amount), animated: true)
        return .result()
    }
}

struct GetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Monitor Brightness"
    static let description = IntentDescription("Returns the external monitor's current brightness.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let controller = BrightnessController.shared
        await controller.refresh()
        let level = Int(controller.level.rounded())
        return .result(value: level, dialog: "The monitor is at \(level)%.")
    }
}

struct SwitchInputIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Monitor Input"
    static let description = IntentDescription(
        "Switches the external monitor to another video input. This Mac's picture goes away until you switch back.")

    @Parameter(title: "Input")
    var input: InputChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Switch monitor to \(\.$input)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await BrightnessController.shared.switchInput(to: MonitorInput(code: input.code))
        return .result()
    }
}

enum InputChoice: String, AppEnum {
    case displayPort, usbC, hdmi1, hdmi2

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Monitor Input"
    static let caseDisplayRepresentations: [InputChoice: DisplayRepresentation] = [
        .displayPort: "DisplayPort",
        .usbC: "USB-C (DP 2)",
        .hdmi1: "HDMI 1",
        .hdmi2: "HDMI 2",
    ]

    var code: Int {
        switch self {
        case .displayPort: 0x0F
        case .usbC: 0x10
        case .hdmi1: 0x11
        case .hdmi2: 0x12
        }
    }
}

struct ScreenBrightnessShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ApplyPresetIntent(),
            phrases: [
                "Apply \(\.$preset) in \(.applicationName)",
                "Set \(.applicationName) to \(\.$preset)",
            ],
            shortTitle: "Apply Preset",
            systemImageName: "sun.max")
        AppShortcut(
            intent: SetBrightnessIntent(),
            phrases: ["Set monitor brightness with \(.applicationName)"],
            shortTitle: "Set Brightness",
            systemImageName: "slider.horizontal.3")
        AppShortcut(
            intent: GetBrightnessIntent(),
            phrases: ["What's the monitor brightness in \(.applicationName)"],
            shortTitle: "Get Brightness",
            systemImageName: "sun.min")
        AppShortcut(
            intent: TurnOffMonitorIntent(),
            phrases: ["Turn off the monitor with \(.applicationName)"],
            shortTitle: "Turn Off Monitor",
            systemImageName: "moon.zzz")
    }
}
