import SwiftUI

/// Content of the menu bar window.
struct BrightnessMenu: View {
    let controller: BrightnessController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MenuHeader(name: controller.display?.name ?? "External Display",
                       status: controller.status,
                       level: controller.level,
                       isHDRActive: controller.isHDRActive)

            if controller.status == .unavailable {
                UnavailableNotice(retry: { Task { await controller.refresh() } })
            } else {
                BrightnessSlider(value: controller.level,
                                 minimum: controller.minimumLevel,
                                 onChange: { controller.setLevel($0) })
                    .disabled(controller.status != .ready)
                PresetGrid(presets: controller.presets,
                           current: controller.level,
                           select: controller.apply(preset:))
                    .disabled(controller.status != .ready)
                if let state = controller.scheduleState {
                    ScheduleStatus(state: state, presets: controller.presets,
                                   pausedUntil: controller.schedulePausedUntil,
                                   resume: controller.resumeSchedule)
                }
                if controller.changeIgnored {
                    IgnoredChangeNotice(isHDRActive: controller.isHDRActive)
                }
            }

            if controller.status == .ready {
                Divider()
                MonitorControls(controller: controller)
            }

            if !controller.inputTap.isTrusted {
                Divider()
                KeyAccessRow(inputTap: controller.inputTap)
            }

            Divider()

            MenuFooter()
        }
        .padding(16)
        .frame(width: 320)
        // The window is reused between openings, so resync with the monitor each time it is shown.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await controller.refresh() }
        }
    }
}

/// Sun glyph that shrinks at low brightness and turns into a moon when extra dimming kicks in.
struct BrightnessSymbol: View {
    let level: Double

    static func name(for level: Double) -> String {
        level < 0 ? "moon.fill" : level < 34 ? "sun.min.fill" : "sun.max.fill"
    }

    var body: some View {
        Image(systemName: Self.name(for: level))
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct MenuHeader: View {
    let name: String
    let status: BrightnessController.Status
    let level: Double
    let isHDRActive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if isHDRActive {
                        Text("HDR")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(level / 100, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(level < 0 ? AnyShapeStyle(.indigo) : AnyShapeStyle(.primary))
                .contentTransition(.numericText(value: level))
                .animation(.snappy, value: level)
                .opacity(status == .ready ? 1 : 0.35)
        }
    }

    private var subtitle: LocalizedStringKey {
        switch status {
        case .connecting: "Connecting…"
        case .ready: level < 0 ? "Extra dimming" : "Hardware brightness"
        case .unavailable: "Not responding"
        }
    }
}

/// A Control Center–style slider: a thick track with a tinted fill and a round knob.
/// The part left of the zero mark is extra (software) dimming.
private struct BrightnessSlider: View {
    let value: Double
    let minimum: Double
    let onChange: (Double) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false

    private let height: CGFloat = 24

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: minimum < 0 ? "moon.fill" : "sun.min.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            track
            Image(systemName: "sun.max.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var track: some View {
        GeometryReader { proxy in
            let travel = proxy.size.width - height
            let range = 100 - minimum
            let fillWidth = height + travel * (value - minimum) / range
            let zeroX = height / 2 + travel * -minimum / range

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(value < 0 ? AnyShapeStyle(Color.indigo.gradient) : AnyShapeStyle(Color.accentColor.gradient))
                    .frame(width: fillWidth)
                if minimum < 0 {
                    Capsule()
                        .fill(.secondary.opacity(0.5))
                        .frame(width: 2, height: height * 0.4)
                        .offset(x: zeroX - 1)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: isDragging ? 4 : 2, y: 1)
                    .padding(2)
                    .scaleEffect(isDragging ? 1.08 : 1)
                    .frame(width: height, height: height)
                    .offset(x: fillWidth - height)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let fraction = min(max((gesture.location.x - height / 2) / max(travel, 1), 0), 1)
                        onChange(minimum + fraction * range)
                    }
                    .onEnded { _ in isDragging = false }
            )
            .animation(.snappy(duration: 0.15), value: isDragging)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Brightness")
        .accessibilityValue(Text(value / 100, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(value + BrightnessLevel.keyStep)
            case .decrement: onChange(value - BrightnessLevel.keyStep)
            @unknown default: break
            }
        }
    }
}

private struct PresetGrid: View {
    let presets: [Preset]
    let current: Double
    let select: (Preset) -> Void

    private let columns = [GridItem(.adaptive(minimum: 66), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(presets) { preset in
                Button {
                    select(preset)
                } label: {
                    VStack(spacing: 1) {
                        Text(preset.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(Double(preset.level) / 100, format: .percent)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .opacity(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PresetButtonStyle(isSelected: Int(current.rounded()) == preset.level))
            }
        }
    }
}

private struct PresetButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.7)),
                        in: .rect(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.rect(cornerRadius: 10))
            .animation(.snappy(duration: 0.15), value: isSelected)
    }
}

private struct UnavailableNotice: View {
    let retry: () -> Void

    var body: some View {
        NoticeCard(systemImage: "exclamationmark.triangle.fill", tint: .orange,
                   title: "The monitor didn't answer",
                   message: "Make sure DDC/CI is turned on in the monitor's settings menu.") {
            Button("Try Again", action: retry)
        }
    }
}

private struct IgnoredChangeNotice: View {
    let isHDRActive: Bool

    var body: some View {
        if isHDRActive {
            NoticeCard(systemImage: "sun.max.trianglebadge.exclamationmark", tint: .orange,
                       title: "Brightness is locked in HDR",
                       message: "The monitor ignores brightness changes while HDR is on. Turn HDR off for this display to use the slider.") {
                Button("Open Displays Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                }
            }
        } else {
            NoticeCard(systemImage: "sun.max.trianglebadge.exclamationmark", tint: .orange,
                       title: "The monitor ignored the change",
                       message: "Its current picture mode may lock brightness. Pick a different mode in the monitor's own menu.") {
                EmptyView()
            }
        }
    }
}

private struct NoticeCard<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}

/// What the schedule is doing: one line, or a pause notice with a way back.
private struct ScheduleStatus: View {
    let state: ScheduleState
    let presets: [Preset]
    let pausedUntil: Date?
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: pausedUntil == nil ? "calendar.badge.clock" : "pause.circle")
                .foregroundStyle(.secondary)
            Group {
                if let pausedUntil {
                    Text("Paused until \(time(pausedUntil))")
                } else {
                    Text("\(name(of: state.current)) until \(time(state.nextAt)), then \(name(of: state.next))")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer(minLength: 4)
            if pausedUntil != nil {
                Button("Resume", action: resume)
                    .controlSize(.mini)
            }
        }
    }

    private func name(of entry: ScheduleEntry) -> String {
        presets.first { $0.id == entry.presetID }?.name ?? "?"
    }

    private func time(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        return Calendar.current.isDateInToday(date) ? time : "tomorrow \(time)"
    }
}

/// Picks the monitor's colour temperature preset.
private struct ColorRow: View {
    let controller: BrightnessController

    var body: some View {
        HStack {
            SettingLabel(title: "Color", systemImage: "thermometer.medium")
            Spacer()
            Menu {
                ForEach(controller.colorPresets) { preset in
                    Toggle(preset.name, isOn: Binding(
                        get: { controller.colorPreset == preset },
                        set: { _ in controller.setColorPreset(preset) }))
                }
            } label: {
                Text(controller.colorPreset?.name ?? "Unknown")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// Picks the monitor's video input. Leaving this Mac's input needs a second click to confirm.
private struct InputRow: View {
    let controller: BrightnessController

    @State private var pendingInput: MonitorInput?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SettingLabel(title: "Input", systemImage: "cable.connector.horizontal")
                Spacer()
                Menu {
                    ForEach(controller.inputs) { input in
                        Toggle(input.name, isOn: Binding(
                            get: { controller.currentInput == input },
                            set: { _ in
                                if input != controller.currentInput { pendingInput = input }
                            }))
                    }
                } label: {
                    Text(controller.currentInput?.name ?? "Unknown")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }

            if let pendingInput {
                NoticeCard(systemImage: "arrow.left.arrow.right", tint: .accentColor,
                           title: "Switch to \(pendingInput.name)?",
                           message: "This Mac's picture goes away until you switch back with the monitor's buttons.") {
                    HStack {
                        Button("Cancel") { self.pendingInput = nil }
                        Button("Switch") {
                            self.pendingInput = nil
                            Task { await controller.switchInput(to: pendingInput) }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: pendingInput)
    }
}

private struct KeyAccessRow: View {
    let inputTap: SystemInputTap

    var body: some View {
        NoticeCard(systemImage: "keyboard", tint: .accentColor,
                   title: "Brightness keys and scrolling are off",
                   message: "Allow Accessibility access so F1/F2 and scrolling on the menu bar icon can change brightness.") {
            Button("Enable…", action: inputTap.requestAccess)
        }
    }
}

/// Contrast, volume and input: the monitor's other controls, shown when it supports them.
private struct MonitorControls: View {
    let controller: BrightnessController

    var body: some View {
        VStack(spacing: 10) {
            if let contrast = controller.contrast {
                CompactSliderRow(title: "Contrast", systemImage: "circle.lefthalf.filled",
                                 value: contrast, onChange: controller.setContrast)
            }
            if !controller.colorPresets.isEmpty {
                ColorRow(controller: controller)
            }
            if controller.isMonitorAudioActive, let volume = controller.volume {
                VolumeRow(controller: controller, volume: volume)
            }
            if !controller.inputs.isEmpty {
                InputRow(controller: controller)
            }
        }
    }
}

private struct CompactSliderRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: Double
    let onChange: @MainActor @Sendable (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            SettingLabel(title: title, systemImage: systemImage)
                .frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: 0...100)
                .controlSize(.small)
            Text(value, format: .number.precision(.fractionLength(0)))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

private struct VolumeRow: View {
    let controller: BrightnessController
    let volume: Double

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller.setMuted(!controller.isMuted)
            } label: {
                Label {
                    Text("Volume")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(controller.isMuted ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 16)
                }
            }
            .buttonStyle(.plain)
            .help(controller.isMuted ? "Unmute" : "Mute")
            .frame(width: 92, alignment: .leading)

            Slider(value: Binding(get: { volume }, set: { controller.setVolume($0) }), in: 0...100)
                .controlSize(.small)
                .opacity(controller.isMuted ? 0.5 : 1)
            Text(volume, format: .number.precision(.fractionLength(0)))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

private struct SettingLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .font(.system(size: 12))
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }
}

private struct MenuFooter: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            Text("Screen Brightness")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                // Give the click time to finish, or releasing the mouse wakes the display straight away.
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    DisplaySleep.sleepNow()
                }
            } label: {
                Image(systemName: "moon.zzz")
            }
            .controlSize(.small)
            .help("Turn off the monitor. Any key or mouse movement turns it back on.")
            Button("Settings…") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",")
            .controlSize(.small)
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .controlSize(.small)
        }
    }
}
