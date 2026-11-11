// Renders GitPad's placeholder app icon: SF Symbol "arrow.triangle.branch" on an orange gradient.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let gradient = NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.45, blue: 0.22, alpha: 1),
                          ending: NSColor(srgbRed: 0.85, green: 0.20, blue: 0.20, alpha: 1))!
gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
