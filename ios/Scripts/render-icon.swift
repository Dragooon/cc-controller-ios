import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("ios/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func render(background: NSColor, star: NSColor, output: URL) throws {
    let size = 1024
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: size * 4,
        bitsPerPixel: 32
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "Icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    background.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 500, weight: .regular),
        .foregroundColor: star,
    ]
    let glyph = NSAttributedString(string: "✻", attributes: attributes)
    let bounds = glyph.size()
    glyph.draw(at: NSPoint(x: (CGFloat(size) - bounds.width) / 2, y: (CGFloat(size) - bounds.height) / 2 - 20))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 2)
    }
    try png.write(to: output)
}

try render(background: NSColor(calibratedRed: 0x12 / 255, green: 0x11 / 255, blue: 0x10 / 255, alpha: 1), star: NSColor(calibratedRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1), output: root.appendingPathComponent("AppIcon.png"))
try render(background: NSColor(calibratedRed: 0x12 / 255, green: 0x11 / 255, blue: 0x10 / 255, alpha: 1), star: NSColor(calibratedWhite: 0.92, alpha: 1), output: root.appendingPathComponent("AppIcon-dark.png"))
try render(background: NSColor.white, star: NSColor.black, output: root.appendingPathComponent("AppIcon-tinted.png"))
