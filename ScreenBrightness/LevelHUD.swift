import AppKit
import Observation
import SwiftUI

/// The on-screen indicator shown while changing brightness or volume from the keyboard or
/// the menu bar icon: a glass pill in the top-right corner of the monitor, like the system HUD.
@MainActor
final class LevelHUD {
    struct Content: Equatable {
        var systemImage: String
        var title: String
        /// How full the bar is, 0…1.
        var fraction: Double
        /// Shown as a percentage on the right.
        var value: Double
        /// Replaces the percentage, e.g. "Muted".
        var valueText: String?
        /// Indigo instead of the default colour, for extra dimming.
        var isAccented = false
    }

    @MainActor
    @Observable
    final class Model {
        var content = Content(systemImage: "sun.max.fill", title: "", fraction: 0, value: 0)
    }

    /// Sits just above the extra-dimming overlay so the HUD stays readable.
    static let windowLevel = NSWindow.Level(rawValue: SoftwareDimmer.overlayWindowLevel.rawValue + 1)

    private let model = Model()
    private lazy var hostingController = NSHostingController(rootView: LevelHUDView(model: model))
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ content: Content, on screen: NSScreen?) {
        withAnimation(.snappy(duration: 0.18)) {
            model.content = content
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
        panel.level = Self.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

private struct LevelHUDView: View {
    let model: LevelHUD.Model

    var body: some View {
        let content = model.content
        HStack(spacing: 12) {
            Image(systemName: content.systemImage)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 7) {
                Text(content.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                LevelBar(fraction: content.fraction, tint: content.isAccented ? .indigo : .primary)
                    .frame(height: 6)
            }

            Group {
                if let valueText = content.valueText {
                    Text(valueText)
                } else {
                    Text(content.value / 100, format: .percent.precision(.fractionLength(0)))
                        .contentTransition(.numericText(value: content.value))
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 300)
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
                        .frame(width: max(proxy.size.height, proxy.size.width * min(max(fraction, 0), 1)))
                }
        }
    }
}
