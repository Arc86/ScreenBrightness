import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    enum Pane: Hashable {
        case general, keyboard, presets
    }

    let controller: BrightnessController
    @State private var pane: Pane

    init(controller: BrightnessController, pane: Pane = .general) {
        self.controller = controller
        self.pane = pane
    }

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettings(controller: controller)
            }
            Tab("Keyboard", systemImage: "keyboard", value: .keyboard) {
                KeyboardSettings(controller: controller)
            }
            Tab("Presets", systemImage: "square.grid.2x2", value: .presets) {
                PresetSettings(controller: controller)
            }
        }
        .frame(width: 480, height: 640)
    }
}

private struct GeneralSettings: View {
    @Bindable var controller: BrightnessController

    var body: some View {
        Form {
            Section {
                Toggle("Smooth transitions", isOn: $controller.smoothTransitions)
                Toggle(isOn: $controller.allowsExtraDimming) {
                    Text("Extra dimming below 0%")
                    Text("Keeps dimming in software once the monitor reaches its minimum. Useful at night on an OLED.")
                }
                if controller.allowsExtraDimming {
                    Picker(selection: $controller.dimmingMethod) {
                        Text("Color tables").tag(SoftwareDimmer.Method.gamma)
                        Text("Overlay").tag(SoftwareDimmer.Method.overlay)
                    } label: {
                        Text("Dimming method")
                        Text(controller.dimmingMethod == .gamma
                             ? "Deepest blacks. Can clash with Night Shift or f.lux while dimmed."
                             : "Works alongside Night Shift and f.lux.")
                    }
                }
            } header: {
                Text("Brightness")
            } footer: {
                if controller.allowsExtraDimming {
                    Text("While HDR is on, the overlay is always used. Neither method shows up in screenshots.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Dim when idle", isOn: $controller.dimsWhenIdle)
                if controller.dimsWhenIdle {
                    Picker("After", selection: $controller.idleMinutes) {
                        ForEach(BrightnessController.idleMinuteChoices, id: \.self) { minutes in
                            Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                        }
                    }
                }
            } header: {
                Text("Idle")
            } footer: {
                Text(idleFooter)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { controller.launchesAtLogin },
                                                        set: { controller.setLaunchesAtLogin($0) }))
            }

            Section {
                LabeledContent("Shortcuts") {
                    Button("Open Shortcuts") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                    }
                }
            } footer: {
                Text("Set brightness, apply a preset or switch inputs from Shortcuts or Siri. Add a personal automation to change brightness at sunset or when a Focus turns on.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var idleFooter: String {
        let base = "Fades the monitor to 0% when you step away and restores it as soon as you're back. Easier on an OLED."
        guard controller.dimsWhenIdle, !controller.idleDimBlockers.isEmpty else {
            return base + " Skipped while an app keeps the display awake, such as a video player."
        }
        return base + " Last skipped because \(controller.idleDimBlockers.formatted(.list(type: .and))) kept the display awake."
    }
}

private struct KeyboardSettings: View {
    @Bindable var controller: BrightnessController

    var body: some View {
        Form {
            Section {
                LabeledContent("Brighter") {
                    ShortcutRecorder(hotkey: $controller.brighterHotkey,
                                     isConflicting: controller.hotkeyConflicts.contains(.up))
                }
                LabeledContent("Dimmer") {
                    ShortcutRecorder(hotkey: $controller.dimmerHotkey,
                                     isConflicting: controller.hotkeyConflicts.contains(.down))
                }
            } header: {
                Text("Brightness Shortcuts")
            } footer: {
                Text("Work from any app. Hold to keep changing. The F1/F2 brightness keys and scrolling on the menu bar icon also work.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $controller.controlsMonitorVolume) {
                    Text("Volume keys control the monitor")
                    Text("When sound plays through the monitor over HDMI or DisplayPort, macOS can't change its volume. The volume and mute keys then go to the monitor instead.")
                }
            } header: {
                Text("Volume")
            }

            if !controller.inputTap.isTrusted {
                Section {
                    LabeledContent("Accessibility access") {
                        Button("Enable…", action: controller.inputTap.requestAccess)
                    }
                } footer: {
                    Text("Needed for the F1/F2 keys, the volume keys and scrolling on the menu bar icon. Custom shortcuts work without it.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PresetSettings: View {
    @Bindable var controller: BrightnessController

    var body: some View {
        Form {
            Section {
                List {
                    ForEach($controller.presets) { $preset in
                        PresetEditorRow(preset: $preset, minimum: Int(controller.minimumLevel)) {
                            controller.presets.removeAll { $0.id == preset.id }
                        }
                    }
                    .onMove { controller.presets.move(fromOffsets: $0, toOffset: $1) }
                }
            } footer: {
                HStack {
                    Text("Click a name to rename it. Drag to reorder.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Current Level") { controller.addPreset() }
                    Button("Add Preset") { controller.addPreset(level: 50) }
                }
                .disabled(controller.presets.count >= Preset.maximumCount)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PresetEditorRow: View {
    @Binding var preset: Preset
    let minimum: Int
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("Name", text: $preset.name)
                .labelsHidden()
                .frame(width: 120)
            Slider(value: Binding(get: { Double(preset.level) }, set: { preset.level = Int($0.rounded()) }),
                   in: Double(min(minimum, preset.level))...100)
            Text(Double(preset.level) / 100, format: .percent)
                .monospacedDigit()
                .foregroundStyle(preset.level < 0 ? AnyShapeStyle(.indigo) : AnyShapeStyle(.secondary))
                .frame(width: 44, alignment: .trailing)
            Button(role: .destructive, action: delete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete preset")
        }
    }
}

/// Click to record a new shortcut; Esc cancels and Delete clears it.
private struct ShortcutRecorder: View {
    @Binding var hotkey: Hotkey?
    let isConflicting: Bool

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if isConflicting && !isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another app already uses this shortcut.")
            }
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Type shortcut…" : hotkey?.displayString ?? "Record Shortcut")
                    .monospaced(hotkey != nil && !isRecording)
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            if hotkey != nil && !isRecording {
                Button {
                    hotkey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stopRecording()
            case kVK_Delete where event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty,
                 kVK_ForwardDelete where event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty:
                hotkey = nil
                stopRecording()
            default:
                guard let recorded = Hotkey(event: event) else {
                    NSSound.beep()
                    return nil
                }
                hotkey = recorded
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
