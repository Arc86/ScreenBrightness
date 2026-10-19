import Foundation

/// A named brightness level. Negative levels use extra (software) dimming.
struct Preset: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var level: Int

    static let maximumCount = 8

    static let defaults: [Preset] = [
        Preset(name: "Night", level: -20),
        Preset(name: "Evening", level: 20),
        Preset(name: "Day", level: 50),
        Preset(name: "Bright", level: 100),
    ]

    private static let storageKey = "presets"

    static func load() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let presets = try? JSONDecoder().decode([Preset].self, from: data) else { return defaults }
        return presets
    }

    static func save(_ presets: [Preset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: storageKey)
    }
}
