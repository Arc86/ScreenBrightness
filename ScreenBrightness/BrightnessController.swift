import AppKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class BrightnessController {
    enum Status: Equatable {
        case connecting, ready, unavailable
    }

    static let shared = BrightnessController()

    /// Sixteen steps across the hardware range, like the built-in display keys.
    static let keyStep = 100.0 / 16
    /// Lowest level when extra dimming is on. At this level the picture runs at 20% of the hardware minimum.
    static let extraDimFloor = -50.0

    private(set) var status: Status = .connecting
    private(set) var display: ExternalDisplay?
    /// 0…100 is the monitor's hardware brightness. Below 0 the monitor stays at its minimum
    /// and the picture is dimmed further in software, down to `extraDimFloor`.
    private(set) var level: Double = 50
    private(set) var inputs: [MonitorInput] = []
    private(set) var currentInput: MonitorInput?
    /// Set when the monitor reported a different brightness than the one just sent.
    private(set) var changeIgnored = false
    private(set) var isHDRActive = false
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    var presets: [Preset] = Preset.load() {
        didSet {
            Preset.save(presets)
            ScreenBrightnessShortcuts.updateAppShortcutParameters()
        }
    }
    var smoothTransitions = UserDefaults.standard.object(forKey: "smoothTransitions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(smoothTransitions, forKey: "smoothTransitions") }
    }
    var allowsExtraDimming = UserDefaults.standard.object(forKey: "allowsExtraDimming") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(allowsExtraDimming, forKey: "allowsExtraDimming")
            if !allowsExtraDimming && targetLevel < 0 { setLevel(0) }
        }
    }

    var brighterHotkey = loadHotkey("brighterHotkey", default: .defaultBrighter) {
        didSet { saveHotkey(brighterHotkey, as: "brighterHotkey"); registerHotkeys() }
    }
    var dimmerHotkey = loadHotkey("dimmerHotkey", default: .defaultDimmer) {
        didSet { saveHotkey(dimmerHotkey, as: "dimmerHotkey"); registerHotkeys() }
    }
    /// Shortcuts another app already owns.
    private(set) var hotkeyConflicts: Set<BrightnessDirection> = []

    var minimumLevel: Double { allowsExtraDimming ? Self.extraDimFloor : 0 }

    let inputTap = SystemInputTap()

    @ObservationIgnored private let link = DDCLink()
    @ObservationIgnored private let hud = BrightnessHUD()
    @ObservationIgnored private let dimmer = SoftwareDimmer()
    @ObservationIgnored private let hotkeys = HotkeyCenter()
    /// Where the level is heading, which runs ahead of `level` during a fade.
    @ObservationIgnored private var targetLevel: Double = 50
    @ObservationIgnored private var lastHardwareValue: Int?
    /// Bumped on every local change so a slow read never overwrites a fresher user value.
    @ObservationIgnored private var changeGeneration = 0
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var verifyTask: Task<Void, Never>?

    private init() {
        // Clear any dimming left behind if a previous run crashed.
        dimmer.reset()

        inputTap.onBrightnessKey = { [weak self] direction, fine in
            self?.step(direction: direction, fine: fine)
        }
        inputTap.onStatusItemScroll = { [weak self] deltaY, isPrecise in
            self?.scroll(deltaY: deltaY, isPrecise: isPrecise)
        }
        inputTap.start()
        hotkeys.onPress = { [weak self] direction in
            self?.step(direction: direction, fine: false)
        }
        registerHotkeys()

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnect() }
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dimmer.reset() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnect() }
        }
        Task { await refresh() }
        #if DEBUG
        openDebugPreviewIfRequested()
        #endif
    }

    // MARK: Reading

    /// Re-reads the monitor so the UI matches changes made with the monitor's own buttons.
    func refresh() async {
        display = ExternalDisplay.current()
        isHDRActive = display?.isHDRActive ?? false

        let generation = changeGeneration
        guard let reading = await link.read(.brightness) else {
            status = .unavailable
            return
        }
        status = .ready
        let hardware = (Double(reading.current) / Double(reading.maximum) * 100).rounded()
        // At hardware 0 the extra-dim level is ours to keep; anything else means the monitor changed.
        if generation == changeGeneration, !(hardware == 0 && level < 0) {
            level = hardware
            targetLevel = hardware
            lastHardwareValue = Int(hardware)
            dimmer.apply(1, to: display?.displayID)
        }

        if inputs.isEmpty {
            inputs = await loadInputs()
        }
        if !inputs.isEmpty, let input = await link.read(.input) {
            currentInput = inputs.first { $0.code == input.current } ?? MonitorInput(code: input.current)
        }
    }

    /// The input list comes from the monitor's capabilities string, cached per model since it takes ~1 s to read.
    private func loadInputs() async -> [MonitorInput] {
        guard let display else { return [] }
        let key = "capabilities.\(display.storageKey)"
        if let cached = UserDefaults.standard.string(forKey: key) {
            return MonitorInput.supported(inCapabilities: cached)
        }
        guard let capabilities = await link.readCapabilities() else { return [] }
        UserDefaults.standard.set(capabilities, forKey: key)
        return MonitorInput.supported(inCapabilities: capabilities)
    }

    // MARK: Changing brightness

    func setLevel(_ value: Double, animated: Bool = false, showHUD: Bool = false) {
        let target = min(max(value, minimumLevel), 100)
        targetLevel = target
        fadeTask?.cancel()
        fadeTask = nil

        if animated && smoothTransitions && abs(target - level) > 1 {
            let start = level
            fadeTask = Task { [weak self] in
                let frames = 8
                for frame in 1...frames {
                    try? await Task.sleep(for: .milliseconds(35))
                    guard !Task.isCancelled, let self else { return }
                    let progress = Double(frame) / Double(frames)
                    let eased = 1 - pow(1 - progress, 3)
                    self.apply(start + (target - start) * eased)
                }
            }
        } else {
            apply(target)
        }

        if showHUD {
            hud.show(level: target, minimumLevel: minimumLevel, displayName: display?.name, on: display?.screen)
        }
    }

    func apply(preset: Preset) {
        setLevel(Double(preset.level), animated: true)
    }

    func step(direction: BrightnessDirection, fine: Bool) {
        let step = fine ? Self.keyStep / 4 : Self.keyStep
        let delta = direction == .up ? step : -step
        // Snap to the step grid so repeated presses land on the same values.
        let target = ((targetLevel + delta) / step).rounded() * step
        setLevel(target, showHUD: true)
    }

    private func scroll(deltaY: Double, isPrecise: Bool) {
        // Trackpads and free-spinning wheels send many small precise deltas; notched wheels send one per click.
        let change = isPrecise ? deltaY * 0.25 : (deltaY > 0 ? 1 : -1) * Self.keyStep / 2
        setLevel(targetLevel + change, showHUD: true)
    }

    private func apply(_ value: Double) {
        changeGeneration += 1
        level = value

        let hardware = Int(max(value, 0).rounded())
        if hardware != lastHardwareValue {
            lastHardwareValue = hardware
            link.setBrightness(hardware)
            scheduleVerification(expecting: hardware)
        }
        // Linear from full picture at 0 down to 20% at the floor.
        let dimFactor = value < 0 ? 1 - 0.8 * value / Self.extraDimFloor : 1
        dimmer.apply(dimFactor, to: display?.displayID)
    }

    /// Reads the brightness back shortly after a change to catch monitors that lock it (HDR, Eco modes).
    private func scheduleVerification(expecting expected: Int) {
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let reading = await self.link.read(.brightness),
                  !Task.isCancelled else { return }
            let actual = Int((Double(reading.current) / Double(reading.maximum) * 100).rounded())
            self.changeIgnored = abs(actual - expected) > 2
            self.isHDRActive = self.display?.isHDRActive ?? false
        }
    }

    // MARK: Inputs

    func switchInput(to input: MonitorInput) async {
        guard await link.write(.input, value: input.code) else { return }
        currentInput = input
    }

    // MARK: Settings

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ScreenBrightness: launch at login change failed: \(error)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func addPreset(level: Int? = nil) {
        guard presets.count < Preset.maximumCount else { return }
        presets.append(Preset(name: "Preset \(presets.count + 1)", level: level ?? Int(targetLevel.rounded())))
    }

    private func registerHotkeys() {
        hotkeys.register(brighter: brighterHotkey, dimmer: dimmerHotkey)
        hotkeyConflicts = hotkeys.conflicts
    }

    private func reconnect() {
        link.reset()
        dimmer.reapply()
        Task { await refresh() }
    }
}

/// A missing value means "use the default"; an empty value means the user cleared the shortcut.
private func loadHotkey(_ key: String, default defaultHotkey: Hotkey) -> Hotkey? {
    guard let data = UserDefaults.standard.data(forKey: key) else { return defaultHotkey }
    return data.isEmpty ? nil : try? JSONDecoder().decode(Hotkey.self, from: data)
}

private func saveHotkey(_ hotkey: Hotkey?, as key: String) {
    let data = hotkey.flatMap { try? JSONEncoder().encode($0) } ?? Data()
    UserDefaults.standard.set(data, forKey: key)
}
