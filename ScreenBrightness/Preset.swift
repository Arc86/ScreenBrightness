import Foundation

/// A named brightness level. Negative levels use extra (software) dimming.
struct Preset: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var level: Int
    /// Colour temperature to switch to (a `ColorPreset` code), or nil to leave it alone.
    var colorPreset: Int?

    static let maximumCount = 8

    static let defaults: [Preset] = [
        Preset(name: "Night", level: -20),
        Preset(name: "Evening", level: 20),
        Preset(name: "Day", level: 50),
        Preset(name: "Bright", level: 100),
    ]

    private static let storageKey = "presets"

    /// Presets live in the shared store so the Control Center extension can list them.
    /// Versions before the extension kept them in the app's own defaults.
    static func load(from store: UserDefaults = SharedStore.defaults) -> [Preset] {
        guard let data = store.data(forKey: storageKey) ?? UserDefaults.standard.data(forKey: storageKey),
              let presets = try? JSONDecoder().decode([Preset].self, from: data) else { return defaults }
        return presets
    }

    static func save(_ presets: [Preset], to store: UserDefaults = SharedStore.defaults) {
        store.set(try? JSONEncoder().encode(presets), forKey: storageKey)
    }
}
