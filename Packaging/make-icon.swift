import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift <output.png>\n", stderr)
    exit(2)
}

let canvasSize = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvasSize)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let backgroundRect = NSRect(x: 60, y: 60, width: 904, height: 904)
let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: 205, yRadius: 205)
let gradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.12, green: 0.49, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.23, green: 0.69, blue: 0.96, alpha: 1)
    ]
)
gradient?.draw(in: backgroundPath, angle: -50)

let innerPath = NSBezierPath(
    roundedRect: NSRect(x: 112, y: 112, width: 800, height: 800),
    xRadius: 165,
    yRadius: 165
)
NSColor.white.withAlphaComponent(0.12).setFill()
innerPath.fill()

if let symbol = NSImage(
    systemSymbolName: "arrow.triangle.2.circlepath",
    accessibilityDescription: nil
)?.withSymbolConfiguration(
    NSImage.SymbolConfiguration(pointSize: 500, weight: .bold)
) {
    let tintedSymbol = NSImage(size: symbol.size)
    tintedSymbol.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
    NSColor.white.setFill()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tintedSymbol.unlockFocus()

    let symbolRect = NSRect(x: 252, y: 252, width: 520, height: 520)
    tintedSymbol.draw(
        in: symbolRect,
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: nil
    )
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let representation = NSBitmapImageRep(data: tiff),
      let png = representation.representation(using: .png, properties: [:]) else {
    fputs("Unable to render icon\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
