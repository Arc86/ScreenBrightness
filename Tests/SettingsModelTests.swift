import Carbon.HIToolbox
import Foundation
import Testing

@Suite struct SettingsModelTests {
    @Test func defaultShortcutsDisplayAndMapToCarbon() {
        #expect(Hotkey.defaultBrighter.displayString == "⌃⌥⌘↑")
        #expect(Hotkey.defaultDimmer.displayString == "⌃⌥⌘↓")
        #expect(Hotkey.defaultBrighter.carbonModifiers == UInt32(cmdKey | optionKey | controlKey))
    }

    @Test func functionKeysNeedNoModifiers() {
        #expect(Hotkey(keyCode: UInt32(kVK_F13), modifiers: 0).displayString == "F13")
    }

    @Test func hotkeysRoundTrip() throws {
        let data = try JSONEncoder().encode(Hotkey.defaultDimmer)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == .defaultDimmer)
    }

    @Test func presetsRoundTrip() throws {
        let data = try JSONEncoder().encode(Preset.defaults)
        #expect(try JSONDecoder().decode([Preset].self, from: data) == Preset.defaults)
    }

    @Test func defaultPresetsIncludeExtraDimming() {
        #expect(Preset.defaults.contains { $0.level < 0 })
        #expect(Preset.defaults.count <= Preset.maximumCount)
    }
}

@Suite struct SharedStoreTests {
    @Test func commandsRoundTrip() {
        let id = UUID()
        for command in [SharedStore.Command.step(.up), .step(.down), .applyPreset(id), .turnOffMonitor] {
            #expect(SharedStore.Command(rawValue: command.rawValue) == command)
        }
        #expect(SharedStore.Command(rawValue: "preset:not-a-uuid") == nil)
        #expect(SharedStore.Command(rawValue: "") == nil)
    }

    @Test func presetsWithoutAColorDecode() throws {
        // Saved by versions before colour presets existed.
        let json = #"[{"id":"6C1D7B0E-2F0C-4C55-9F38-1E4C2D7B9A10","name":"Day","level":50}]"#
        let presets = try JSONDecoder().decode([Preset].self, from: Data(json.utf8))
        #expect(presets.first?.colorPreset == nil)
        #expect(presets.first?.level == 50)
    }

    @Test func presetsLoadFromTheGivenStore() throws {
        let store = try #require(UserDefaults(suiteName: "ScreenBrightnessTests.\(UUID().uuidString)"))
        let presets = [Preset(name: "Warm", level: 30, colorPreset: 0x04)]
        Preset.save(presets, to: store)
        #expect(Preset.load(from: store) == presets)
    }
}
