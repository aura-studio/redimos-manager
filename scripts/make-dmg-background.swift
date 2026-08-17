import AppKit

// dmg-bg-b.swift <out.png>
// REAL DMG background, variant B (dashed arc + motion trail), 1280x800 px.
// Coordinates are the approved mockup B's, minus the icon placeholders,
// labels and window chrome (Finder overlays the real icons + names).
// Sequoia Finder renders backgrounds 1 image-px = 1pt, so the shipped file is
// this art downscaled to 640x400 (supersampled for crisper text).

let OUT = CommandLine.arguments[1]
let W = 1280, H = 800

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func rt(_ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: CGFloat(H) - yTop - h, width: w, height: h)
}

func drawTextC(_ s: String, _ size: CGFloat, _ c: NSColor, cx: CGFloat, cyCenter: CGFloat, bold: Bool = false) {
    let f = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    let str = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
    let sz = str.size()
    str.draw(at: NSPoint(x: cx - sz.width / 2, y: CGFloat(H) - cyCenter - sz.height / 2))
}

// canvas — v1 light chrome background
color(0xF7F8FA).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// title (mockup B: cy 190px)
drawTextC("Redimos Manager", 52, color(0x1F2937), cx: CGFloat(W) / 2, cyCenter: 190, bold: true)

// motion trail left of the app icon slot (mockup B coords)
for (i, a) in [CGFloat(0.35), CGFloat(0.22), CGFloat(0.12)].enumerated() {
    let t = NSBezierPath(roundedRect: rt(120 - CGFloat(i) * 14, 396 + CGFloat(i) * 18, 96 - CGFloat(i) * 18, 12), xRadius: 6, yRadius: 6)
    color(0x3B6EA5, a).setFill(); t.fill()
}

// dashed arc app->Applications with arrowhead (mockup B coords)
let arc = NSBezierPath()
arc.move(to: NSPoint(x: 410, y: CGFloat(H) - 350))
arc.curve(to: NSPoint(x: 848, y: CGFloat(H) - 368),
          controlPoint1: NSPoint(x: 560, y: CGFloat(H) - 210),
          controlPoint2: NSPoint(x: 780, y: CGFloat(H) - 220))
color(0x3B6EA5).setStroke()
arc.lineWidth = 10
arc.lineCapStyle = .round
arc.setLineDash([22, 16], count: 2, phase: 0)
arc.stroke()
let hd = NSBezierPath()
hd.move(to: NSPoint(x: 871, y: CGFloat(H) - 418))
hd.line(to: NSPoint(x: 879, y: CGFloat(H) - 354))
hd.line(to: NSPoint(x: 817, y: CGFloat(H) - 382))
hd.close()
color(0x3B6EA5).setFill(); hd.fill()

// caption kept at 560px (mockup's 655 would collide with the README icon)
drawTextC("拖到 Applications 文件夹安装  ·  Drag to Applications to install",
          28, color(0x6B7280), cx: CGFloat(W) / 2, cyCenter: 560)

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: OUT))
