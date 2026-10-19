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
