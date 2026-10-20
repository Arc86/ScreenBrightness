import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    enum Pane: Hashable {
        case general, keyboard, presets, schedule
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
            Tab("Schedule", systemImage: "calendar.badge.clock", value: .schedule) {
                ScheduleSettings(controller: controller)
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
                Toggle(isOn: $controller.turnsOffWhenLocked) {
                    Text("Turn off the monitor when the screen locks")
                    Text("Instead of showing the lock screen until the display goes to sleep on its own. Easier on an OLED.")
                }
                if controller.turnsOffWhenLocked {
                    Picker("After", selection: $controller.lockDelay) {
                        ForEach(BrightnessController.lockDelayChoices, id: \.self) { seconds in
                            Text(seconds < 60 ? "\(seconds) seconds" : "1 minute").tag(seconds)
                        }
                    }
                }
            } header: {
                Text("Screen Lock")
            } footer: {
                Text("The displays go to sleep, which any key or mouse movement undoes. If they wake at the lock screen and are left alone, they go back to sleep.")
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
                        PresetEditorRow(preset: $preset, minimum: Int(controller.minimumLevel),
                                        colorPresets: controller.colorPresets) {
                            controller.presets.removeAll { $0.id == preset.id }
                        }
                    }
                    .onMove { controller.presets.move(fromOffsets: $0, toOffset: $1) }
                }
            } footer: {
                HStack {
                    Text(controller.colorPresets.isEmpty
                         ? "Click a name to rename it. Drag to reorder."
                         : "Click a name to rename it. Drag to reorder. A preset can also switch the monitor's color temperature.")
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
    let colorPresets: [ColorPreset]
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("Name", text: $preset.name)
                .labelsHidden()
                .frame(width: colorPresets.isEmpty ? 120 : 96)
            Slider(value: Binding(get: { Double(preset.level) }, set: { preset.level = Int($0.rounded()) }),
                   in: Double(min(minimum, preset.level))...100)
            Text(Double(preset.level) / 100, format: .percent)
                .monospacedDigit()
                .foregroundStyle(preset.level < 0 ? AnyShapeStyle(.indigo) : AnyShapeStyle(.secondary))
                .frame(width: 44, alignment: .trailing)
            if !colorPresets.isEmpty {
                Picker("Color", selection: $preset.colorPreset) {
                    Text("Keep Color").tag(Int?.none)
                    Divider()
                    ForEach(colorPresets) { color in
                        Text(color.name).tag(Optional(color.code))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Color temperature to switch to")
            }
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

private struct ScheduleSettings: View {
    @Bindable var controller: BrightnessController

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $controller.schedule.isEnabled) {
                    Text("Follow a schedule")
                    Text("Applies presets through the day, fading from one to the next.")
                }
            } footer: {
                Text("Changing brightness yourself pauses the schedule until its next change.")
                    .foregroundStyle(.secondary)
            }

            Section {
                List {
                    ForEach($controller.schedule.entries) { $entry in
                        ScheduleEntryRow(entry: $entry, presets: controller.presets,
                                         sunTimes: sunTimes) {
                            controller.schedule.entries.removeAll { $0.id == entry.id }
                        }
                    }
                }
                Picker("Transition", selection: $controller.schedule.transitionMinutes) {
                    ForEach(BrightnessSchedule.transitionChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Instant" : minutes < 60 ? "\(minutes) minutes" : "1 hour").tag(minutes)
                    }
                }
            } header: {
                Text("Times")
            } footer: {
                HStack {
                    Text("The transition starts at each time.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Time", action: addEntry)
                        .disabled(controller.schedule.entries.count >= BrightnessSchedule.maximumEntries
                                  || controller.presets.isEmpty)
                }
            }

            if controller.schedule.usesSun {
                Section {
                    LocationRow(location: controller.sunLocation, sunTimes: sunTimes)
                } header: {
                    Text("Sunrise and Sunset")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sunTimes: SunTimes? {
        controller.sunLocation.coordinate.flatMap { SunTimes(on: .now, at: $0, calendar: .current) }
    }

    private func addEntry() {
        guard let preset = controller.presets.first else { return }
        controller.schedule.entries.append(ScheduleEntry(trigger: .time, minutes: 12 * 60, presetID: preset.id))
    }
}

private struct ScheduleEntryRow: View {
    @Binding var entry: ScheduleEntry
    let presets: [Preset]
    let sunTimes: SunTimes?
    let delete: () -> Void

    private static let offsets = [-60, -30, -15, 0, 15, 30, 60]

    var body: some View {
        HStack(spacing: 8) {
            Picker("When", selection: $entry.trigger) {
                Text("At").tag(ScheduleEntry.Trigger.time)
                Text("Sunrise").tag(ScheduleEntry.Trigger.sunrise)
                Text("Sunset").tag(ScheduleEntry.Trigger.sunset)
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: entry.trigger) { old, new in
                // Switching between a clock time and the sun: start from a sensible value.
                if (old == .time) != (new == .time) { entry.minutes = new == .time ? 12 * 60 : 0 }
            }

            if entry.trigger == .time {
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
            } else {
                Picker("Offset", selection: $entry.minutes) {
                    ForEach(Self.offsets, id: \.self) { minutes in
                        Text(offsetName(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let date = sunDate {
                    Text(date, format: .dateTime.hour().minute())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
            Picker("Preset", selection: $entry.presetID) {
                ForEach(presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
                if !presets.contains(where: { $0.id == entry.presetID }) {
                    Text("Deleted Preset").tag(entry.presetID)
                }
            }
            .labelsHidden()
            .fixedSize()

            Button(role: .destructive, action: delete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove time")
        }
    }

    private func offsetName(_ minutes: Int) -> String {
        switch minutes {
        case 0: "on time"
        case ..<0: "\(-minutes) min before"
        default: "\(minutes) min after"
        }
    }

    private var sunDate: Date? {
        guard let sunTimes else { return nil }
        let base = entry.trigger == .sunrise ? sunTimes.sunrise : sunTimes.sunset
        return base.addingTimeInterval(Double(entry.minutes) * 60)
    }

    /// Minutes after midnight shown as a time today.
    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(entry.minutes) * 60) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                entry.minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }
}

private struct LocationRow: View {
    let location: SunLocation
    let sunTimes: SunTimes?

    var body: some View {
        switch location.status {
        case .locating:
            LabeledContent("Location") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Locating…")
                }
            }
        case .denied:
            LabeledContent {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
            } label: {
                Text("Location access is off")
                Text("Sunrise and sunset times need your approximate location. Clock times still work.")
            }
        case .failed where location.coordinate == nil:
            LabeledContent {
                Button("Try Again", action: location.locate)
            } label: {
                Text("Couldn't find your location")
                Text("Location Services may be turned off in System Settings.")
            }
        default:
            if let sunTimes {
                LabeledContent("Today") {
                    Text("Sunrise \(sunTimes.sunrise, format: .dateTime.hour().minute()) · Sunset \(sunTimes.sunset, format: .dateTime.hour().minute())")
                        .monospacedDigit()
                }
            } else if location.coordinate != nil {
                LabeledContent("Today", value: "The sun doesn't rise or set")
            } else {
                LabeledContent("Location") {
                    Button("Find My Location", action: location.locate)
                }
            }
        }
    }
}
