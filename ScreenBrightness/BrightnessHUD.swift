import AppKit
import Observation
import SwiftUI

/// The on-screen indicator shown while using the brightness keys: a glass pill in the
/// top-right corner of the monitor being adjusted, like the system volume HUD.
@MainActor
final class BrightnessHUD {
    @MainActor
    @Observable
    final class Model {
        var level: Double = 0
        var minimumLevel: Double = 0
        var displayName = "External Display"
    }

    private let model = Model()
    private lazy var hostingController = NSHostingController(rootView: BrightnessHUDView(model: model))
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(level: Double, minimumLevel: Double, displayName: String?, on screen: NSScreen?) {
        model.displayName = displayName ?? "External Display"
        withAnimation(.snappy(duration: 0.18)) {
            model.level = level
            model.minimumLevel = minimumLevel
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(hostingController.sizeThatFits(in: NSSize(width: 1000, height: 1000)))
        if let screen = screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 12,
                                         y: frame.maxY - panel.frame.height - 12))
        }
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = panel.isVisible ? panel.alphaValue : 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.35; panel.animator().alphaValue = 0 }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentViewController = hostingController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

private struct BrightnessHUDView: View {
    let model: BrightnessHUD.Model

    var body: some View {
        HStack(spacing: 12) {
            BrightnessSymbol(level: model.level)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 7) {
                Text(model.level < 0 ? "Extra dimming" : model.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                LevelBar(fraction: (model.level - model.minimumLevel) / (100 - model.minimumLevel),
                         tint: model.level < 0 ? .indigo : .primary)
                    .frame(height: 6)
            }

            Text(model.level / 100, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: model.level))
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 290)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(10)
    }
}

private struct LevelBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(proxy.size.height, proxy.size.width * fraction))
                }
        }
    }
}
