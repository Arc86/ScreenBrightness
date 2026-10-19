// Renders the app icon set into ScreenBrightness/Assets.xcassets. Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let assets = root.appendingPathComponent("ScreenBrightness/Assets.xcassets")
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    // Apple's macOS icon grid: 824pt body centred on a 1024pt canvas.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill(); shape.fill()
    NSShadow().set()

    NSGradient(colors: [NSColor(red: 0.13, green: 0.16, blue: 0.36, alpha: 1),
                        NSColor(red: 0.30, green: 0.22, blue: 0.62, alpha: 1)])!.draw(in: shape, angle: 90)
    NSGradient(colors: [NSColor(red: 1.0, green: 0.78, blue: 0.30, alpha: 0.55), .clear])!
        .draw(in: NSBezierPath(ovalIn: body.insetBy(dx: 120 * s, dy: 120 * s)), relativeCenterPosition: .zero)

    let config = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 1.0, green: 0.86, blue: 0.45, alpha: 1)]))
    let sun = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    sun.draw(in: NSRect(x: body.midX - sun.size.width / 2, y: body.midY - sun.size.height / 2,
                        width: sun.size.width, height: sun.size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: points * scale).write(to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(to: assets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(iconSet.path)")
