#!/usr/bin/env swift

// Regenerates App/Assets.xcassets/AppIcon.appiconset PNGs: a garage-door
// glyph (matching the menu bar icon) on a squircle gradient background.
// Run from the repo root: swift scripts/generate-app-icon.swift

import AppKit

let sizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let outDir = "App/Assets.xcassets/AppIcon.appiconset"

func squirclePath(in rect: NSRect) -> NSBezierPath {
    // Apple's icon corner radius is ~22.37% of the canvas size.
    let radius = rect.width * 0.2237
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func makeIcon(pixelSize: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons live in ~80% of the canvas with transparent margin
    // around them (Big Sur+ icon grid), not full bleed.
    let inset = CGFloat(pixelSize) * 0.10
    let contentRect = NSRect(x: inset, y: inset, width: CGFloat(pixelSize) - inset * 2, height: CGFloat(pixelSize) - inset * 2)

    let bgPath = squirclePath(in: contentRect)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.62, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.34, alpha: 1.0)
    )!
    gradient.draw(in: bgPath, angle: -90)

    let glyphFraction: CGFloat = 0.60
    let glyphSize = contentRect.width * glyphFraction
    let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "door.garage.closed", accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    else {
        fatalError("door.garage.closed symbol unavailable")
    }
    let symSize = symbol.size
    let origin = NSPoint(
        x: (CGFloat(pixelSize) - symSize.width) / 2,
        y: (CGFloat(pixelSize) - symSize.height) / 2
    )
    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for entry in sizes {
    let pixelSize = entry.points * entry.scale
    let rep = makeIcon(pixelSize: pixelSize)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG for \(pixelSize)px")
    }
    let filename = "icon_\(entry.points)x\(entry.points)@\(entry.scale)x.png"
    let path = "\(outDir)/\(filename)"
    try! data.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path) (\(pixelSize)x\(pixelSize)px)")
}
