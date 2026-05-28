// Generate a 1024x1024 PNG used as the source for AppIcon.icns.
// Run via tools/make_icon.sh, which also resizes and packages with iconutil.
//
// Design: macOS-style squircle, diagonal gradient from Gemini blue (top-left)
// to Claude coral (bottom-right), white gauge SF Symbol centered.
import AppKit

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

// Draw into an explicit RGBA bitmap so we always have a backing PNG-able
// representation. Using NSImage.lockFocus + tiffRepresentation can fail to
// finalize a TIFF on macOS Sequoia.
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("Failed to allocate bitmap\n".utf8))
    exit(1)
}

let gctx = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
defer { NSGraphicsContext.restoreGraphicsState() }

let ctx = gctx.cgContext
ctx.setShouldAntialias(true)

// Squircle background.
let radius: CGFloat = size * 0.225
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
ctx.saveGState()
bgPath.addClip()

// Diagonal gradient: top-left blue → bottom-right coral, matching the
// per-service brand colors used in the menubar and dropdown.
let geminiBlue = NSColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1).cgColor
let claudeCoral = NSColor(red: 0.92, green: 0.45, blue: 0.30, alpha: 1).cgColor
let gradient = CGGradient(
    colorsSpace: nil,
    colors: [geminiBlue, claudeCoral] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),         // top-left (flipped coordinates)
    end: CGPoint(x: size, y: 0),           // bottom-right
    options: []
)
ctx.restoreGState()

// White gauge symbol, ~55% of canvas, centered.
let symbolConfig = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
guard let symbol = NSImage(
    systemSymbolName: "gauge.with.dots.needle.50percent",
    accessibilityDescription: nil
)?.withSymbolConfiguration(symbolConfig) else {
    FileHandle.standardError.write(Data("Failed to load symbol\n".utf8))
    exit(1)
}
let drawRect = NSRect(
    x: (size - symbol.size.width) / 2,
    y: (size - symbol.size.height) / 2,
    width: symbol.size.width,
    height: symbol.size.height
)
symbol.draw(in: drawRect)

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Failed to encode PNG\n".utf8))
    exit(1)
}

do {
    try data.write(to: URL(fileURLWithPath: outputPath))
    print("Wrote \(outputPath)")
} catch {
    FileHandle.standardError.write(Data("Failed to write: \(error)\n".utf8))
    exit(1)
}
