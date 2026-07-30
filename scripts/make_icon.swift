#!/usr/bin/env swift
//
// Renders Resources/icon_1024.png.
//
// The icon is now generated from the *same* SF Symbol the app draws in its own
// UI — `externaldrive.fill.badge.plus` on the Hub gradient, exactly as
// `AppTheme.glyph(size:)` renders it in Theme.swift. The previous generator
// hand-drew an approximation in pure Python, which is why the Dock and the
// README slowly drifted away from the mark shown inside the app and ended up
// looking like something else entirely.
//
// Requires macOS, because SF Symbols live there. `scripts/make_app.sh` runs this
// before building the iconset, so the Dock icon can never disagree with the UI.
//
//     swift scripts/make_icon.swift
//
import AppKit

let size: CGFloat = 1024

// Matches Themes.all["hub"] in Sources/ImageHub/Views/Theme.swift.
let primary = NSColor(srgbRed: 0.16, green: 0.40, blue: 0.92, alpha: 1)
let secondary = NSColor(srgbRed: 0.36, green: 0.74, blue: 0.96, alpha: 1)

// Matches AppTheme.glyph: cornerRadius 0.24, symbol at 0.46 of the tile, semibold.
let cornerRadius = size * 0.24
let symbolPointSize = size * 0.46

/// Recolours a template symbol without tinting anything behind it.
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let output = NSImage(size: image.size)
    output.lockFocus()
    image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    output.unlockFocus()
    return output
}

let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()

let bounds = NSRect(x: 0, y: 0, width: size, height: size)
let tile = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
tile.addClip()

// -45 degrees runs top-left to bottom-right, the same direction as the
// LinearGradient the app uses.
guard let gradient = NSGradient(starting: primary, ending: secondary) else {
    FileHandle.standardError.write(Data("error: could not build the gradient\n".utf8))
    exit(1)
}
gradient.draw(in: bounds, angle: -45)

let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
guard let symbol = NSImage(systemSymbolName: "externaldrive.fill.badge.plus",
                           accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else {
    FileHandle.standardError.write(
        Data("error: SF Symbol externaldrive.fill.badge.plus is unavailable\n".utf8))
    exit(1)
}

let white = tinted(symbol, .white)
let symbolRect = NSRect(
    x: (size - white.size.width) / 2,
    y: (size - white.size.height) / 2,
    width: white.size.width,
    height: white.size.height
)
white.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: could not encode the PNG\n".utf8))
    exit(1)
}

let destination = URL(fileURLWithPath: "Resources/icon_1024.png")
do {
    try png.write(to: destination)
    print("wrote \(destination.path) (\(png.count) bytes)")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
