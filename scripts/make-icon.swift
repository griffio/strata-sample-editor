// Renders the Strata app icon (stacked waveform strata) to a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: 824pt squircle centred in 1024 canvas.
let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = 185
let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.45).cgColor)
color(0x0B0C10).setFill()
tilePath.fill()
ctx.restoreGState()

// Background gradient
ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [color(0x1C2030), color(0x0E1016), color(0x07080B)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: tile, angle: -90)
// Soft glow
let glow = NSGradient(colors: [color(0x4FD1FF, 0.28), color(0x4FD1FF, 0)])!
glow.draw(fromCenter: NSPoint(x: tile.midX, y: tile.midY + 40), radius: 0, toCenter: NSPoint(x: tile.midX, y: tile.midY + 40), radius: 430, options: [])

// Grid lines
for i in 1..<8 {
    let x = tile.minX + tile.width * CGFloat(i) / 8
    color(0xFFFFFF, i % 2 == 0 ? 0.05 : 0.025).setFill()
    NSRect(x: x, y: tile.minY, width: 2, height: tile.height).fill()
}

// Waveform strata
let layers: [(UInt32, CGFloat, CGFloat, Double)] = [
    (0xFF6B6B, 0.70, 0.78, 1.0),
    (0xFFD25A, 0.56, 0.62, 2.2),
    (0x2FE0B0, 0.42, 0.88, 3.1),
    (0x3FD0FF, 0.28, 0.70, 4.7),
]
for (hex, yFrac, amp, seed) in layers {
    let midY = tile.minY + tile.height * (1 - yFrac) - 40
    let laneH: CGFloat = 112
    let path = NSBezierPath()
    var upper: [NSPoint] = [], lower: [NSPoint] = []
    let x0 = tile.minX + 70, x1 = tile.maxX - 70
    let steps = 180
    for s in 0...steps {
        let t = Double(s) / Double(steps)
        let x = x0 + (x1 - x0) * CGFloat(t)
        let env = pow(sin(t * .pi), 0.6)
        let a = abs(sin(t * 23 + seed) * 0.6 + sin(t * 57 + seed * 2) * 0.3 + sin(t * 131 + seed * 3) * 0.18)
        let h = CGFloat(env * (0.25 + a)) * laneH / 2 * amp
        upper.append(NSPoint(x: x, y: midY + h))
        lower.append(NSPoint(x: x, y: midY - h))
    }
    path.move(to: upper[0])
    upper.dropFirst().forEach { path.line(to: $0) }
    lower.reversed().forEach { path.line(to: $0) }
    path.close()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: color(hex, 0.7).cgColor)
    NSGradient(colors: [color(hex, 0.95), color(hex, 0.75)])!.draw(in: path, angle: -90)
    ctx.restoreGState()
    color(0xFFFFFF, 0.08).setFill()
    NSRect(x: x0, y: midY - 1, width: x1 - x0, height: 2).fill()
}

// Playhead
let px = tile.minX + tile.width * 0.62
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: NSColor.white.withAlphaComponent(0.8).cgColor)
NSColor.white.setFill()
NSRect(x: px - 4, y: tile.minY + 90, width: 8, height: tile.height - 200).fill()
let cap = NSBezierPath()
cap.move(to: NSPoint(x: px - 30, y: tile.maxY - 110))
cap.line(to: NSPoint(x: px + 30, y: tile.maxY - 110))
cap.line(to: NSPoint(x: px, y: tile.maxY - 150))
cap.close()
cap.fill()
ctx.restoreGState()

// Top sheen
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
ctx.restoreGState()

// Rim
color(0xFFFFFF, 0.10).setStroke()
let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 1.5, yRadius: radius - 1.5)
rim.lineWidth = 3
rim.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
