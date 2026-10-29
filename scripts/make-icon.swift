// Renders the app icon to a 1024px PNG. Usage: swift scripts/make-icon.swift out.png
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // Rounded square, night-sky gradient (macOS icon grid: 824px tile with ~185px corner radius).
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.10, green: 0.11, blue: 0.24, alpha: 1),
               ending: NSColor(red: 0.30, green: 0.14, blue: 0.42, alpha: 1))!.draw(in: path, angle: -60)

    // Airplane, top.
    let config = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let plane = NSImage(systemSymbolName: "airplane", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = plane.size
        plane.draw(in: NSRect(x: (size - s.width) / 2, y: 480, width: s.width, height: s.height))
    }

    // Five equaliser bars, bottom: the menu bar visualiser.
    NSColor(red: 1.0, green: 0.62, blue: 0.30, alpha: 1).setFill()
    let heights: [Double] = [110, 200, 280, 170, 230]
    let w = 52.0, gap = 34.0
    let startX = (size - (Double(heights.count) * w + Double(heights.count - 1) * gap)) / 2
    for (i, h) in heights.enumerated() {
        let r = NSRect(x: startX + Double(i) * (w + gap), y: 210, width: w, height: h)
        NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
    }
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
