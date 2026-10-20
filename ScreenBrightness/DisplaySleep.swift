import CoreGraphics
import Foundation

/// Putting the displays to sleep, which turns the monitor's panel off until the next key press
/// or mouse movement. Unlike the monitor's DDC power-off, macOS can always wake it again.
enum DisplaySleep {
    static func sleepNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    static var isScreenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func isAsleep(_ displayID: CGDirectDisplayID?) -> Bool {
        CGDisplayIsAsleep(displayID ?? CGMainDisplayID()) != 0
    }

    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
}
