import Foundation

/// Storage the app shares with its Control Center extension: their common app group's defaults.
enum SharedStore {
    /// Falls back to the app's own defaults when the build has no team, and so no app group (an ad hoc build).
    /// UserDefaults is thread-safe, though not marked Sendable.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let teamPrefix = Bundle.main.object(forInfoDictionaryKey: "AppGroupTeamPrefix") as? String, !teamPrefix.isEmpty,
              let defaults = UserDefaults(suiteName: teamPrefix + "com.jespermol.ScreenBrightness") else { return .standard }
        return defaults
    }()

    /// The distributed notification a control posts to ask the running app to do something.
    /// Its object is a `Command` raw value.
    static let commandNotification = Notification.Name("com.jespermol.ScreenBrightness.command")

    enum Command: Equatable, Sendable {
        case step(BrightnessDirection)
        case applyPreset(UUID)
        case turnOffMonitor

        init?(rawValue: String) {
            switch rawValue {
            case "brighter": self = .step(.up)
            case "dimmer": self = .step(.down)
            case "turnOffMonitor": self = .turnOffMonitor
            default:
                guard rawValue.hasPrefix("preset:"), let id = UUID(uuidString: String(rawValue.dropFirst(7))) else { return nil }
                self = .applyPreset(id)
            }
        }

        var rawValue: String {
            switch self {
            case .step(.up): "brighter"
            case .step(.down): "dimmer"
            case .applyPreset(let id): "preset:\(id.uuidString)"
            case .turnOffMonitor: "turnOffMonitor"
            }
        }
    }
}
