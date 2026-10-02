import AppKit
import CoreGraphics
import Foundation

enum IconOption {
    case legacy
    case clayOnCream
    case creamOnClay
    case terminal
}

struct Palette {
    let accent: NSColor
    let lightBackground: NSColor
    let darkBackground: NSColor
    let black: NSColor
    let white: NSColor
}

let palette = Palette(
    accent: NSColor(calibratedRed: 0.788, green: 0.392, blue: 0.259, alpha: 1),
    lightBackground: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1),
    darkBackground: NSColor(calibratedRed: 0.071, green: 0.067, blue: 0.063, alpha: 1),
    black: NSColor(calibratedWhite: 0, alpha: 1),
    white: NSColor(calibratedWhite: 1, alpha: 1)
)
let darkAccent = NSColor(calibratedRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
let warmCream = NSColor(calibratedRed: 0.96, green: 0.958, blue: 0.95, alpha: 1)
let nearBlack = NSColor(calibratedRed: 0.018, green: 0.016, blue: 0.015, alpha: 1)

func option(from argument: String?) -> IconOption {
    guard let argument else { return .legacy }
    switch argument.lowercased() {
    case "a", "option-a", "clay-on-cream": return .clayOnCream
    case "b", "option-b", "cream-on-clay": return .creamOnClay
    case "c", "option-c", "terminal": return .terminal
    case "default", "legacy": return .legacy
    default:
        fputs("unknown icon option: \(argument) (expected a, b, c, or no argument)\n", stderr)
        exit(2)
    }
}

let selectedOption = option(from: CommandLine.arguments.dropFirst().first)
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("ios/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func makeBitmap(size: Int) throws -> (CGContext, NSGraphicsContext) {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw NSError(domain: "Icon", code: 1)
    }
    return (context, NSGraphicsContext(cgContext: context, flipped: false))
}

func drawGradient(_ context: CGContext, in rect: CGRect, top: NSColor, bottom: NSColor) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top.cgColor, bottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )
}

func fill(_ context: CGContext, color: NSColor, in rect: CGRect) {
    context.setFillColor(color.cgColor)
    context.fill(rect)
}

func armPath(center: CGPoint, outerRadius: CGFloat, strokeWidth: CGFloat) -> CGMutablePath {
    let path = CGMutablePath()
    let innerRadius: CGFloat = 0
    for index in 0..<6 {
        let angle = CGFloat(index) * .pi / 3
        let start = CGPoint(
            x: center.x + cos(angle) * innerRadius,
            y: center.y + sin(angle) * innerRadius
        )
        let end = CGPoint(
            x: center.x + cos(angle) * (outerRadius - strokeWidth / 2),
            y: center.y + sin(angle) * (outerRadius - strokeWidth / 2)
        )
        path.move(to: start)
        path.addLine(to: end)
    }
    return path
}

func drawMark(
    _ context: CGContext,
    center: CGPoint,
    width: CGFloat,
    color: NSColor,
    highlight: Bool
) {
    let strokeWidth = width * 0.085
    let outerRadius = width * 0.28
    let path = armPath(center: center, outerRadius: outerRadius, strokeWidth: strokeWidth)

    context.saveGState()
    context.addPath(path)
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(strokeWidth)
    context.setLineCap(.round)
    context.strokePath()

    guard highlight else {
        context.restoreGState()
        return
    }

    context.addPath(path)
    context.replacePathWithStrokedPath()
    context.clip()
    let top = center.y + outerRadius
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedWhite: 1, alpha: 0.18).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0).cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: center.x, y: top),
        end: CGPoint(x: center.x, y: center.y),
        options: []
    )
    context.restoreGState()
}

func drawCursor(_ context: CGContext, center: CGPoint, width: CGFloat, color: NSColor) {
    let cursorWidth = width * 0.2
    let cursorHeight = width * 0.06
    let rect = CGRect(
        x: center.x - cursorWidth / 2,
        y: center.y - cursorHeight / 2,
        width: cursorWidth,
        height: cursorHeight
    )
    context.setFillColor(color.withAlphaComponent(0.85).cgColor)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: cursorHeight / 2, cornerHeight: cursorHeight / 2, transform: nil))
    context.fillPath()
}

func drawLegacy(_ context: CGContext, size: CGFloat, background: NSColor, mark: NSColor) {
    fill(context, color: background, in: CGRect(x: 0, y: 0, width: size, height: size))
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 500, weight: .regular),
        .foregroundColor: mark
    ]
    let glyph = NSAttributedString(string: "✻", attributes: attributes)
    let bounds = glyph.size()
    glyph.draw(at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2 - 20))
}

func drawCandidate(_ context: CGContext, option: IconOption, variant: String, size: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let isTinted = variant == "tinted"
    let isDark = variant == "dark"
    let accent = isDark ? darkAccent : palette.accent
    let markColor = isTinted ? palette.white : accent

    switch option {
    case .clayOnCream:
        if isTinted {
            fill(context, color: palette.black, in: rect)
        } else if isDark {
            drawGradient(context, in: rect, top: palette.darkBackground, bottom: nearBlack)
        } else {
            drawGradient(context, in: rect, top: palette.lightBackground, bottom: warmCream)
        }
        drawMark(context, center: CGPoint(x: size / 2, y: size / 2), width: size, color: isTinted ? palette.white : accent, highlight: !isTinted)

    case .creamOnClay:
        if isTinted {
            fill(context, color: palette.black, in: rect)
        } else if isDark {
            drawGradient(context, in: rect, top: palette.darkBackground, bottom: nearBlack)
        } else {
            let accentBottom = NSColor(
                calibratedRed: accent.redComponent * 0.88,
                green: accent.greenComponent * 0.88,
                blue: accent.blueComponent * 0.88,
                alpha: 1
            )
            drawGradient(context, in: rect, top: accent, bottom: accentBottom)
        }
        drawMark(context, center: CGPoint(x: size / 2, y: size / 2), width: size, color: isTinted ? palette.white : (isDark ? darkAccent : palette.lightBackground), highlight: !isTinted)

    case .terminal:
        drawGradient(context, in: rect, top: isTinted ? palette.black : palette.darkBackground, bottom: nearBlack)
        let center = CGPoint(x: size * 0.445, y: size * 0.555)
        drawMark(context, center: center, width: size * 0.46 / 0.56, color: markColor, highlight: !isTinted)
        drawCursor(context, center: CGPoint(x: size * 0.70, y: size * 0.25), width: size, color: isTinted ? palette.white : palette.lightBackground)

    case .legacy:
        drawLegacy(context, size: size, background: isTinted ? palette.white : palette.darkBackground, mark: isTinted ? palette.black : (isDark ? NSColor(calibratedWhite: 0.92, alpha: 1) : darkAccent))
    }
}

func render(variant: String, option: IconOption, output: URL) throws {
    let size: CGFloat = 1024
    let (context, graphicsContext) = try makeBitmap(size: Int(size))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    drawCandidate(context, option: option, variant: variant, size: size)
    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else {
        throw NSError(domain: "Icon", code: 2)
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 3)
    }
    try png.write(to: output)
}

try render(variant: "light", option: selectedOption, output: root.appendingPathComponent("AppIcon.png"))
try render(variant: "dark", option: selectedOption, output: root.appendingPathComponent("AppIcon-dark.png"))
try render(variant: "tinted", option: selectedOption, output: root.appendingPathComponent("AppIcon-tinted.png"))
