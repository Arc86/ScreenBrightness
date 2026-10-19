import SwiftUI

@main
struct ScreenBrightnessApp: App {
    private let controller = BrightnessController.shared

    var body: some Scene {
        MenuBarExtra {
            BrightnessMenu(controller: controller)
        } label: {
            BrightnessSymbol(level: controller.level)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
        }
    }
}
