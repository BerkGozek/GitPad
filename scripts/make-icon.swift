// Renders GitPad's app icon: SF Symbol "arrow.triangle.branch" on an orange gradient.
// Output is exactly 1024×1024 with no alpha channel (App Store Connect rejects transparency).
// Drawing uses a 32-bit context whose 4th byte is ignored (`noneSkipLast`): CoreGraphics can't
// draw into 24-bit RGB, and drawing into an RGBA bitmap would keep an alpha channel.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import UniformTypeIdentifiers

let size = 1024
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let bounds = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.45, blue: 0.22, alpha: 1),
           ending: NSColor(srgbRed: 0.85, green: 0.20, blue: 0.20, alpha: 1))!
    .draw(in: bounds, angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (Double(size) - s.width) / 2, y: (Double(size) - s.height) / 2, width: s.width, height: s.height))
}
NSGraphicsContext.restoreGraphicsState()

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination), "Couldn't write PNG")
