import AppKit
import Observation
import OSLog
import ServiceManagement

@MainActor
@Observable
final class BrightnessController {
    enum Status: Equatable {
        case connecting, ready, unavailable
    }

    static let shared = BrightnessController()

    static let idleMinuteChoices = [1, 2, 5, 10, 15, 30]
    static let lockDelayChoices = [5, 15, 30, 60]
    private static let log = Logger(subsystem: "com.jespermol.ScreenBrightness", category: "idle")
    private static let scheduleLog = Logger(subsystem: "com.jespermol.ScreenBrightness", category: "schedule")

    // MARK: Monitor state

    private(set) var status: Status = .connecting
    private(set) var display: ExternalDisplay?
    /// See `BrightnessLevel`: 0…100 is hardware brightness, below 0 is extra (software) dimming.
    private(set) var level: Double = 50
    private(set) var capabilities: MonitorCapabilities?
    private(set) var currentInput: MonitorInput?
    /// 0…100, or nil when the monitor doesn't report it.
    private(set) var contrast: Double?
    /// The monitor's colour temperature preset, when it lists them.
    private(set) var colorPreset: ColorPreset?
    private(set) var volume: Double?
    private(set) var isMuted = false
    /// Sound is playing through the monitor, so its volume is ours to control.
    private(set) var isMonitorAudioActive = false
    /// Set when the monitor reported a different brightness than the one just sent.
    private(set) var changeIgnored = false
    private(set) var isHDRActive = false
    /// True while dimmed for inactivity; the next input restores the previous level.
    private(set) var isIdleDimmed = false
    /// Apps currently keeping the display awake, which pauses idle dimming.
    private(set) var idleDimBlockers: [String] = []
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    /// Shortcuts another app already owns.
    private(set) var hotkeyConflicts: Set<BrightnessDirection> = []
    /// Where the schedule stands, while it is on and can be placed in the day.
    private(set) var scheduleState: ScheduleState?
    /// Set by a manual change while the schedule is on; the schedule takes over again at this time.
    private(set) var schedulePausedUntil: Date? = UserDefaults.standard.object(forKey: "schedulePausedUntil") as? Date {
        didSet { UserDefaults.standard.set(schedulePausedUntil, forKey: "schedulePausedUntil") }
    }

    var inputs: [MonitorInput] { capabilities?.inputs ?? [] }
    var colorPresets: [ColorPreset] { capabilities?.colorPresets ?? [] }
    var minimumLevel: Double { allowsExtraDimming ? BrightnessLevel.extraDimFloor : 0 }

    // MARK: Settings

    var presets: [Preset] = Preset.load() {
        didSet {
            Preset.save(presets)
            ScreenBrightnessShortcuts.updateAppShortcutParameters()
            if schedule.isEnabled { updateSchedule() }
        }
    }
    var schedule = StoredSettings.schedule() {
        didSet {
            StoredSettings.set(schedule)
            if !schedule.isEnabled || schedule.entries != oldValue.entries {
                // Start over: the next update fades in from wherever the new schedule says it should be.
                activeScheduleEntryID = nil
                schedulePausedUntil = nil
            }
            if schedule.usesSun { sunLocation.updateIfNeeded() }
            updateSchedule()
        }
    }
    var turnsOffWhenLocked = StoredSettings.bool("turnsOffWhenLocked", default: false) {
        didSet { StoredSettings.set(turnsOffWhenLocked, for: "turnsOffWhenLocked") }
    }
    /// Seconds after locking before the displays go to sleep.
    var lockDelay = StoredSettings.integer("lockDelay", default: 15) {
        didSet { StoredSettings.set(lockDelay, for: "lockDelay") }
    }
    var smoothTransitions = StoredSettings.bool("smoothTransitions", default: true) {
        didSet { StoredSettings.set(smoothTransitions, for: "smoothTransitions") }
    }
    var allowsExtraDimming = StoredSettings.bool("allowsExtraDimming", default: true) {
        didSet {
            StoredSettings.set(allowsExtraDimming, for: "allowsExtraDimming")
            if !allowsExtraDimming && targetLevel < 0 { setLevel(0) }
        }
    }
    var dimmingMethod = SoftwareDimmer.Method(rawValue: StoredSettings.string("dimmingMethod") ?? "") ?? .gamma {
        didSet {
            StoredSettings.set(dimmingMethod.rawValue, for: "dimmingMethod")
            applyDimming()
        }
    }
    var dimsWhenIdle = StoredSettings.bool("dimsWhenIdle", default: true) {
        didSet { StoredSettings.set(dimsWhenIdle, for: "dimsWhenIdle") }
    }
    var idleMinutes = StoredSettings.integer("idleMinutes", default: 5) {
        didSet { StoredSettings.set(idleMinutes, for: "idleMinutes") }
    }
    var controlsMonitorVolume = StoredSettings.bool("controlsMonitorVolume", default: true) {
        didSet { StoredSettings.set(controlsMonitorVolume, for: "controlsMonitorVolume") }
    }
    var brighterHotkey = StoredSettings.hotkey("brighterHotkey", default: .defaultBrighter) {
        didSet { StoredSettings.set(brighterHotkey, for: "brighterHotkey"); registerHotkeys() }
    }
    var dimmerHotkey = StoredSettings.hotkey("dimmerHotkey", default: .defaultDimmer) {
        didSet { StoredSettings.set(dimmerHotkey, for: "dimmerHotkey"); registerHotkeys() }
    }

    let inputTap = SystemInputTap()
    let sunLocation = SunLocation()

    @ObservationIgnored private let link = DDCLink()
    @ObservationIgnored private let hud = LevelHUD()
    @ObservationIgnored private let dimmer = SoftwareDimmer()
    @ObservationIgnored private let hotkeys = HotkeyCenter()
    /// Where the level is heading, which runs ahead of `level` during a fade.
    @ObservationIgnored private var targetLevel: Double = 50
    @ObservationIgnored private var lastHardwareValue: Int?
    /// Bumped on every local change so a slow read never overwrites a fresher user value.
    @ObservationIgnored private var changeGeneration = 0
    @ObservationIgnored private var hasRestoredExtraDimming = false
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    @ObservationIgnored private var idleRestoreLevel: Double?
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var scheduleTimer: Timer?
    /// The entry the schedule last faded into, and the level that fade started from.
    @ObservationIgnored private var activeScheduleEntryID: UUID?
    @ObservationIgnored private var scheduleFadeStart: Double = 50
    @ObservationIgnored private var lockTask: Task<Void, Never>?
    /// A control's command that launched the app, run once the monitor answers.
    @ObservationIgnored private var launchCommand = UserDefaults.standard.string(forKey: "command").flatMap(SharedStore.Command.init)
    #if DEBUG
    @ObservationIgnored private let createdAt = Date.now
    #endif

    private init() {
        // Copies presets saved by older versions into the shared store, where the controls extension reads them.
        Preset.save(presets)
        inputTap.onBrightnessKey = { [weak self] direction, fine in
            self?.step(direction: direction, fine: fine)
        }
        inputTap.onVolumeKey = { [weak self] key, fine in
            self?.handleVolumeKey(key, fine: fine) ?? false
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
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: DisplaySleep.lockedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked() }
        }
        distributed.addObserver(forName: DisplaySleep.unlockedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lockTask?.cancel()
                self?.lockTask = nil
            }
        }
        distributed.addObserver(forName: SharedStore.commandNotification, object: nil, queue: .main) { [weak self] notification in
            let command = (notification.object as? String).flatMap(SharedStore.Command.init)
            MainActor.assumeIsolated {
                if let command { self?.perform(command) }
            }
        }
        sunLocation.onChange = { [weak self] in self?.updateSchedule() }
        if schedule.isEnabled && schedule.usesSun { sunLocation.updateIfNeeded() }
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSchedule() }
        }
        scheduleIdleCheck(after: 5)
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
        isMonitorAudioActive = SystemStatus.isOutputtingToDisplayAudio()

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
            restoreExtraDimmingIfNeeded(hardware: hardware)
            applyDimming()
        }

        if capabilities == nil {
            capabilities = await loadCapabilities()
        }
        await refreshMonitorControls()

        updateSchedule()
        if let command = launchCommand {
            launchCommand = nil
            perform(command)
        }
    }

    /// After a restart the monitor still sits at 0, but the software dimming on top of it is gone.
    private func restoreExtraDimmingIfNeeded(hardware: Double) {
        guard !hasRestoredExtraDimming else { return }
        hasRestoredExtraDimming = true
        let saved = UserDefaults.standard.double(forKey: "extraDimLevel")
        guard hardware == 0, saved < 0, allowsExtraDimming else { return }
        level = max(saved, minimumLevel)
        targetLevel = level
    }

    private func refreshMonitorControls() async {
        guard let capabilities else { return }
        if !capabilities.inputs.isEmpty, let input = await link.read(.input) {
            currentInput = capabilities.inputs.first { $0.code == input.current } ?? MonitorInput(code: input.current)
        }
        if capabilities.supports(.contrast), let reading = await link.read(.contrast) {
            contrast = percent(reading)
        }
        if !colorPresets.isEmpty, let reading = await link.read(.colorPreset) {
            let code = ColorPreset.fromReading(reading.current, monitor: display?.storageKey)
            colorPreset = colorPresets.first { $0.code == code }
        }
        if capabilities.supports(.volume), let reading = await link.read(.volume) {
            volume = percent(reading)
        }
        if capabilities.supports(.mute), let reading = await link.read(.mute) {
            isMuted = reading.current == 1
        }
    }

    /// Cached per monitor model, since the capabilities string takes about a second to read.
    private func loadCapabilities() async -> MonitorCapabilities? {
        guard let display else { return nil }
        let key = "capabilities.\(display.storageKey)"
        if let cached = UserDefaults.standard.string(forKey: key) {
            return MonitorCapabilities(parsing: cached)
        }
        guard let string = await link.readCapabilities() else { return nil }
        UserDefaults.standard.set(string, forKey: key)
        return MonitorCapabilities(parsing: string)
    }

    private func percent(_ reading: (current: Int, maximum: Int)) -> Double {
        (Double(reading.current) / Double(reading.maximum) * 100).rounded()
    }

    // MARK: Brightness

    /// A deliberate change by the user, from the menu, keys, presets or Shortcuts.
    func setLevel(_ value: Double, animated: Bool = false, showHUD: Bool = false) {
        // Any deliberate change ends an idle dim; there is nothing left to restore.
        endIdleDim(restoring: false)
        pauseSchedule()
        changeLevel(to: value, duration: animated ? 0.3 : 0, showHUD: showHUD)
    }

    func apply(preset: Preset) {
        setLevel(Double(preset.level), animated: true)
        applyColor(of: preset)
    }

    /// Runs a command sent by a Control Center control.
    func perform(_ command: SharedStore.Command) {
        switch command {
        case .step(let direction):
            step(direction: direction, fine: false)
        case .applyPreset(let id):
            if let preset = presets.first(where: { $0.id == id }) { apply(preset: preset) }
        case .turnOffMonitor:
            DisplaySleep.sleepNow()
        }
    }

    func step(direction: BrightnessDirection, fine: Bool) {
        let step = fine ? BrightnessLevel.keyStep / 4 : BrightnessLevel.keyStep
        setLevel(BrightnessLevel.stepped(from: targetLevel, direction: direction, step: step), showHUD: true)
    }

    private func scroll(deltaY: Double, isPrecise: Bool) {
        // Trackpads and free-spinning wheels send many small precise deltas; notched wheels send one per click.
        let change = isPrecise ? deltaY * 0.25 : (deltaY > 0 ? 1 : -1) * BrightnessLevel.keyStep / 2
        setLevel(targetLevel + change, showHUD: true)
    }

    private func changeLevel(to value: Double, duration: Double, showHUD: Bool = false) {
        let target = min(max(value, minimumLevel), 100)
        targetLevel = target
        fadeTask?.cancel()
        fadeTask = nil

        if duration > 0 && smoothTransitions && abs(target - level) > 1 {
            let start = level
            let frames = max(Int(duration / 0.035), 2)
            fadeTask = Task { [weak self] in
                for frame in 1...frames {
                    try? await Task.sleep(for: .milliseconds(35))
                    guard !Task.isCancelled, let self else { return }
                    let progress = Double(frame) / Double(frames)
                    let eased = 1 - pow(1 - progress, 3)
                    self.applyLevel(start + (target - start) * eased)
                }
            }
        } else {
            applyLevel(target)
        }

        if showHUD {
            hud.show(LevelHUD.Content(
                systemImage: BrightnessSymbol.name(for: target),
                title: target < 0 ? "Extra dimming" : display?.name ?? "External Display",
                fraction: (target - minimumLevel) / (100 - minimumLevel),
                value: target,
                isAccented: target < 0), on: display?.screen)
        }
    }

    private func applyLevel(_ value: Double) {
        changeGeneration += 1
        level = value

        let hardware = BrightnessLevel.hardwareValue(for: value)
        if hardware != lastHardwareValue {
            lastHardwareValue = hardware
            link.set(.brightness, value: hardware)
            scheduleVerification(expecting: hardware)
        }
        applyDimming()

        if value < 0 {
            UserDefaults.standard.set(value, forKey: "extraDimLevel")
        } else {
            UserDefaults.standard.removeObject(forKey: "extraDimLevel")
        }
    }

    /// HDR ignores gamma tables, so the overlay takes over while HDR is on.
    private func applyDimming() {
        let method: SoftwareDimmer.Method = isHDRActive ? .overlay : dimmingMethod
        dimmer.apply(BrightnessLevel.dimFactor(for: level), to: display?.displayID, method: method)
    }

    /// Reads the brightness back shortly after a change to catch monitors that lock it (HDR, Eco modes).
    private func scheduleVerification(expecting expected: Int) {
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let reading = await self.link.read(.brightness),
                  !Task.isCancelled else { return }
            self.changeIgnored = abs(Int(self.percent(reading)) - expected) > 2
            self.isHDRActive = self.display?.isHDRActive ?? false
        }
    }

    // MARK: Idle dimming

    private func scheduleIdleCheck(after interval: TimeInterval) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    private func checkIdle() {
        var idleSeconds = SystemStatus.secondsSinceLastInput() ?? 0
        var threshold = Double(idleMinutes * 60)
        #if DEBUG
        // SB_IDLE_SECONDS shortens the threshold; SB_FAKE_IDLE_UNTIL=<s> reports idle for that long after launch.
        if let override = ProcessInfo.processInfo.environment["SB_IDLE_SECONDS"].flatMap(Double.init) { threshold = override }
        if let fakeUntil = ProcessInfo.processInfo.environment["SB_FAKE_IDLE_UNTIL"].flatMap(Double.init) {
            idleSeconds = Date.now.timeIntervalSince(createdAt) < fakeUntil ? 999 : 0
        }
        #endif

        if isIdleDimmed {
            if idleSeconds < 1 {
                Self.log.info("Input after idle, restoring \(self.idleRestoreLevel ?? -1)")
                endIdleDim(restoring: true)
                scheduleIdleCheck(after: 5)
            } else {
                // Poll quickly while dimmed so the screen comes back as soon as the user does.
                scheduleIdleCheck(after: 0.25)
            }
            return
        }

        if dimsWhenIdle, status == .ready, idleSeconds >= threshold {
            idleDimBlockers = SystemStatus.appsPreventingDisplaySleep()
            if idleDimBlockers.isEmpty && targetLevel > 0 {
                Self.log.info("Idle for \(Int(idleSeconds)) s, dimming from \(self.targetLevel)")
                idleRestoreLevel = targetLevel
                isIdleDimmed = true
                changeLevel(to: 0, duration: 2)
                scheduleIdleCheck(after: 0.25)
                return
            }
        }
        // Check again around when the threshold could next be crossed.
        scheduleIdleCheck(after: min(max(threshold - idleSeconds, 5), 30))
    }

    private func endIdleDim(restoring: Bool) {
        guard isIdleDimmed else { return }
        isIdleDimmed = false
        if restoring, let restoreLevel = idleRestoreLevel {
            changeLevel(to: restoreLevel, duration: 0.3)
        }
        idleRestoreLevel = nil
    }

    // MARK: Schedule

    /// Moves brightness towards where the schedule says it should be. Runs every 30 seconds,
    /// so a long transition creeps along a step at a time.
    private func updateSchedule() {
        guard schedule.isEnabled, let state = schedule.state(at: .now, location: sunLocation.coordinate) else {
            scheduleState = nil
            activeScheduleEntryID = nil
            return
        }
        scheduleState = state
        if let pausedUntil = schedulePausedUntil {
            guard Date.now >= pausedUntil else { return }
            schedulePausedUntil = nil
        }
        guard status == .ready else { return }

        if state.current.id != activeScheduleEntryID {
            let isFirstUpdate = activeScheduleEntryID == nil
            activeScheduleEntryID = state.current.id
            // Joining mid-transition (at launch, or when the schedule was just turned on) picks up the fade
            // where it would have been; a new entry fades from wherever brightness is now.
            if isFirstUpdate, let previous = state.previous,
               let previousLevel = presets.first(where: { $0.id == previous.presetID })?.level {
                scheduleFadeStart = Double(previousLevel)
            } else {
                scheduleFadeStart = idleRestoreLevel ?? targetLevel
            }
            if let preset = presets.first(where: { $0.id == state.current.presetID }) {
                Self.scheduleLog.info("Fading into \(preset.name, privacy: .public) from \(self.scheduleFadeStart)")
                applyColor(of: preset)
            }
        }

        guard let level = state.level(from: scheduleFadeStart, presets: presets) else { return }
        let clamped = min(max(level, minimumLevel), 100)
        if isIdleDimmed {
            idleRestoreLevel = clamped
        } else if abs(clamped - targetLevel) >= 0.5 {
            changeLevel(to: clamped, duration: 1)
        }
    }

    private func pauseSchedule() {
        guard schedule.isEnabled, let scheduleState else { return }
        schedulePausedUntil = scheduleState.nextAt
    }

    func resumeSchedule() {
        guard let scheduleState else { return }
        schedulePausedUntil = nil
        activeScheduleEntryID = scheduleState.current.id
        scheduleFadeStart = targetLevel
        if let preset = presets.first(where: { $0.id == scheduleState.current.presetID }) {
            applyColor(of: preset)
        }
        updateSchedule()
    }

    // MARK: Screen lock

    /// Puts the displays to sleep a little after the screen locks, and again whenever they wake
    /// at the lock screen and are left alone, so an OLED doesn't sit on a static image.
    private func screenLocked() {
        lockTask?.cancel()
        guard turnsOffWhenLocked else { return }
        let delay = Double(lockDelay)
        lockTask = Task { [weak self] in
            var wait = delay
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self, self.turnsOffWhenLocked, DisplaySleep.isScreenLocked else { return }
                let idle = SystemStatus.secondsSinceLastInput() ?? 0
                if idle + 0.5 >= delay, !DisplaySleep.isAsleep(self.display?.displayID) {
                    Self.log.info("Screen locked and idle for \(Int(idle)) s, sleeping displays")
                    DisplaySleep.sleepNow()
                }
                wait = 5
            }
        }
    }

    // MARK: Colour, volume and contrast

    func setColorPreset(_ preset: ColorPreset) {
        guard colorPresets.contains(preset) else { return }
        colorPreset = preset
        link.set(.colorPreset, value: preset.code)
        // Some presets (sRGB) lock brightness; read it back so the menu shows what the monitor did.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            await self?.refresh()
        }
    }

    private func applyColor(of preset: Preset) {
        guard let code = preset.colorPreset, code != colorPreset?.code,
              let color = colorPresets.first(where: { $0.code == code }) else { return }
        setColorPreset(color)
    }

    func setContrast(_ value: Double) {
        let value = min(max(value, 0), 100).rounded()
        contrast = value
        link.set(.contrast, value: Int(value))
    }

    func setVolume(_ value: Double, showHUD: Bool = false) {
        let value = min(max(value, 0), 100).rounded()
        volume = value
        link.set(.volume, value: Int(value))
        if isMuted && value > 0 { setMuted(false) }
        if showHUD { showVolumeHUD() }
    }

    func setMuted(_ muted: Bool, showHUD: Bool = false) {
        isMuted = muted
        link.set(.mute, value: muted ? 1 : 2)
        if showHUD { showVolumeHUD() }
    }

    /// Volume keys go to the monitor only while sound plays through it; otherwise macOS handles them.
    private func handleVolumeKey(_ key: SystemInputTap.VolumeKey, fine: Bool) -> Bool {
        guard controlsMonitorVolume, let capabilities, capabilities.supports(.volume),
              SystemStatus.isOutputtingToDisplayAudio() else { return false }
        isMonitorAudioActive = true
        let step = fine ? BrightnessLevel.keyStep / 4 : BrightnessLevel.keyStep
        let current = volume ?? 50
        switch key {
        case .up: setVolume(((current + step) / step).rounded() * step, showHUD: true)
        case .down: setVolume(((current - step) / step).rounded() * step, showHUD: true)
        case .mute: setMuted(!isMuted, showHUD: true)
        }
        return true
    }

    private func showVolumeHUD() {
        let level = volume ?? 0
        let symbol = isMuted || level == 0 ? "speaker.slash.fill"
            : level < 34 ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        hud.show(LevelHUD.Content(
            systemImage: symbol,
            title: "\(display?.name ?? "Monitor") speakers",
            fraction: isMuted ? 0 : level / 100,
            value: level,
            valueText: isMuted ? "Muted" : nil), on: display?.screen)
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

/// UserDefaults access for the settings above.
private enum StoredSettings {
    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static func integer(_ key: String, default value: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? value
    }

    static func string(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func set(_ value: Any, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// A missing value means "use the default"; an empty value means the user cleared the shortcut.
    static func hotkey(_ key: String, default value: Hotkey) -> Hotkey? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return value }
        return data.isEmpty ? nil : try? JSONDecoder().decode(Hotkey.self, from: data)
    }

    static func set(_ hotkey: Hotkey?, for key: String) {
        UserDefaults.standard.set(hotkey.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    /// Until the user sets one up, the schedule is a disabled suggestion built from the presets.
    static func schedule() -> BrightnessSchedule {
        guard let data = UserDefaults.standard.data(forKey: "schedule"),
              let schedule = try? JSONDecoder().decode(BrightnessSchedule.self, from: data) else {
            return .suggested(for: Preset.load())
        }
        return schedule
    }

    static func set(_ schedule: BrightnessSchedule) {
        UserDefaults.standard.set(try? JSONEncoder().encode(schedule), forKey: "schedule")
    }
}
