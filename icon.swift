// Renders the AudioTap app icon: `swift icon.swift out.png` writes a 1024px PNG.
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Squircle on Apple's 1024 grid: 824px body, soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
shape.fill()
ctx.restoreGState()

ctx.saveGState()
shape.addClip()
NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.21, blue: 0.25, alpha: 1), ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1))!
    .draw(in: body, angle: -90)

// Three waveform bars either side of the button.
let heights: [CGFloat] = [140, 250, 190]
let barW: CGFloat = 32, gap: CGFloat = 24, mid = size / 2
for (i, h) in heights.enumerated() {
    let offset = 212 + CGFloat(heights.count - 1 - i) * (barW + gap)
    let alpha = 0.35 + 0.55 * CGFloat(i) / CGFloat(heights.count - 1)
    NSColor.white.withAlphaComponent(alpha).setFill()
    for x in [mid - offset - barW, mid + offset] {
        NSBezierPath(roundedRect: CGRect(x: x, y: mid - h / 2, width: barW, height: h), xRadius: barW / 2, yRadius: barW / 2).fill()
    }
}

// Record button: red disc with a soft glow, a white ring, and a top highlight.
let r: CGFloat = 150
let disc = CGRect(x: mid - r, y: mid - r, width: r * 2, height: r * 2)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 90, color: NSColor(srgbRed: 1, green: 0.2, blue: 0.15, alpha: 0.75).cgColor)
NSColor(srgbRed: 0.93, green: 0.18, blue: 0.14, alpha: 1).setFill()
NSBezierPath(ovalIn: disc).fill()
ctx.restoreGState()
NSGradient(starting: NSColor(srgbRed: 1, green: 0.42, blue: 0.34, alpha: 1), ending: NSColor(srgbRed: 0.80, green: 0.11, blue: 0.09, alpha: 1))!
    .draw(in: NSBezierPath(ovalIn: disc), angle: -90)
let ring = NSBezierPath(ovalIn: disc.insetBy(dx: -34, dy: -34))
ring.lineWidth = 16
NSColor.white.withAlphaComponent(0.9).setStroke()
ring.stroke()
NSGradient(starting: NSColor.white.withAlphaComponent(0.35), ending: NSColor.white.withAlphaComponent(0))!
    .draw(in: NSBezierPath(ovalIn: CGRect(x: mid - r * 0.62, y: mid + r * 0.18, width: r * 1.24, height: r * 0.7)), angle: -90)
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
