#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `SB_PREVIEW=1` opens the menu content in a normal window and
/// flashes the HUD, so the UI can be screenshotted without clicking the menu bar.
/// `SB_PREVIEW_LEVEL=<n>` jumps to a level; `SB_PREVIEW_SETTINGS=general|presets` shows settings.
extension BrightnessController {
    func openDebugPreviewIfRequested() {
        guard ProcessInfo.processInfo.environment["SB_PREVIEW"] != nil else { return }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = "Preview"
        window.contentView = NSHostingView(rootView: BrightnessMenu(controller: self))
        window.center()
        window.makeKeyAndOrderFront(nil)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            step(direction: .up, fine: false)
            if let level = ProcessInfo.processInfo.environment["SB_PREVIEW_LEVEL"].flatMap(Double.init) {
                setLevel(level, showHUD: true)
                try? await Task.sleep(for: .milliseconds(300))
                if let id = display?.displayID {
                    var red = [CGGammaValue](repeating: 0, count: 256), green = red, blue = red
                    var count: UInt32 = 0
                    CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count)
                    print("gamma max after level \(level):", red.prefix(Int(count)).max() ?? -1)
                }
            }
            if ProcessInfo.processInfo.environment["SB_PREVIEW_SETTINGS"] != nil {
                let settings = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
                settings.title = "Settings preview"
                settings.contentView = NSHostingView(rootView: SettingsView(
                    controller: self,
                    pane: ProcessInfo.processInfo.environment["SB_PREVIEW_SETTINGS"] == "presets" ? .presets : .general))
                settings.center()
                settings.makeKeyAndOrderFront(nil)
            }
            fflush(stdout)
        }
    }
}
#endif
