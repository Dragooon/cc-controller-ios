import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let outputPath = arguments.first, arguments.count > 1 else {
    fputs("usage: contact-sheet.swift output.png image.png ...\n", stderr)
    exit(2)
}

let tileWidth: CGFloat = 360
let captionHeight: CGFloat = 34
let gap: CGFloat = 20
let columns = 4
let images = arguments.dropFirst().compactMap { path -> (String, NSImage)? in
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    return (URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, image)
}
guard !images.isEmpty else {
    fputs("no readable images\n", stderr)
    exit(1)
}

let tileHeights = images.map { item in
    let size = item.1.size
    let imageHeight = size.width > 0 ? tileWidth * size.height / size.width : tileWidth
    return imageHeight + captionHeight
}
let rows = Int(ceil(Double(images.count) / Double(columns)))
let rowHeights = (0..<rows).map { row in
    tileHeights[(row * columns)..<min((row + 1) * columns, tileHeights.count)].max() ?? tileWidth
}
let canvasWidth = CGFloat(columns) * tileWidth + CGFloat(columns + 1) * gap
let canvasHeight = rowHeights.reduce(gap, +) + CGFloat(rows) * gap

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasWidth),
    pixelsHigh: Int(canvasHeight),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(calibratedRed: 0x12 / 255, green: 0x11 / 255, blue: 0x10 / 255, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight).fill()

let captionAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1),
]
var y = canvasHeight - gap
for row in 0..<rows {
    let rowHeight = rowHeights[row]
    let rowImages = images[(row * columns)..<min((row + 1) * columns, images.count)]
    for (column, item) in rowImages.enumerated() {
        let x = gap + CGFloat(column) * (tileWidth + gap)
        let size = item.1.size
        let imageHeight = size.width > 0 ? tileWidth * size.height / size.width : tileWidth
        let imageRect = NSRect(x: x, y: y - imageHeight, width: tileWidth, height: imageHeight)
        item.1.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSAttributedString(string: item.0, attributes: captionAttributes)
            .draw(at: NSPoint(x: x, y: y - imageHeight - captionHeight + 8))
    }
    y -= rowHeight + gap
}
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode contact sheet\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
