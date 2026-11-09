// Draws the placeholder app icon: a paper square with a hairline edge, a serif "a" in ink, and
// one amber dot (docs/STYLE.md colors). Usage: swift etc/app/make-icon.swift OUT.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

guard
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("make-icon: could not allocate a bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
rgb(0xF6F1E7).setFill()
path.fill()
rgb(0xC7BCA6).setStroke()
path.lineWidth = 4
path.stroke()

let serif = NSFont.systemFont(ofSize: 560, weight: .regular).fontDescriptor.withDesign(.serif)
let font = serif.flatMap { NSFont(descriptor: $0, size: 560) } ?? NSFont.systemFont(ofSize: 560)
let glyph = NSAttributedString(
    string: "a", attributes: [.font: font, .foregroundColor: rgb(0x1D1B17)])
let bounds = glyph.size()
glyph.draw(at: NSPoint(x: (size - bounds.width) / 2 - 20, y: (size - bounds.height) / 2 + 10))

rgb(0xB13B0B).setFill()
NSBezierPath(ovalIn: NSRect(x: 690, y: 300, width: 64, height: 64)).fill()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("make-icon: could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: out))
