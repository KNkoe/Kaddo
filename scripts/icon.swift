import AppKit

// A static AppKit rendering of the same original Kaddo character used in SwiftUI.
// macOS app icons are static; animation belongs to the visible app companion.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/icon.swift /absolute/output.png\n", stderr)
    exit(1)
}
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let tile = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 218, yRadius: 218)
NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.115, alpha: 1),
           ending: NSColor(calibratedRed: 0.065, green: 0.08, blue: 0.055, alpha: 1))!.draw(in: tile, angle: -65)
let transform = NSAffineTransform()
transform.translateX(by: 512, yBy: 512)
transform.concat()
let tilt = NSAffineTransform()
tilt.rotate(byDegrees: 5)
tilt.concat()
let character = NSBezierPath(roundedRect: NSRect(x: -342, y: -287.28, width: 684, height: 574.56), xRadius: 259.92, yRadius: 259.92)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
shadow.shadowBlurRadius = 25
shadow.shadowOffset = NSSize(width: 0, height: -15)
shadow.set()
NSColor(calibratedRed: 0.72, green: 0.91, blue: 0.46, alpha: 1).setFill()
character.fill()
NSGraphicsContext.restoreGraphicsState()
// Soft sculpted volume: broad upper-left light, moss-green underside, and a lit rim.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func radial(_ stops: [(NSColor, CGFloat)], center: CGPoint, radius: CGFloat) {
    let colors = stops.map { $0.0.cgColor } as CFArray
    let positions = stops.map { $0.1 }
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: positions)!
    context.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                        endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}
NSGraphicsContext.saveGraphicsState()
character.addClip()
radial([(color(0xe5ffb2), 0), (color(0xb8e875), 0.37), (color(0x88bb56), 0.74), (color(0x3e7950), 1)],
       center: CGPoint(x: -144, y: 178), radius: 660)
radial([(color(0xf7ffe1, alpha: 0.54), 0), (color(0xf1ffd8, alpha: 0.12), 0.6), (color(0xf1ffd8, alpha: 0), 1)],
       center: CGPoint(x: -144, y: 195), radius: 370)
radial([(color(0x315e3e, alpha: 0.35), 0), (color(0x315e3e, alpha: 0), 1)],
       center: CGPoint(x: 212, y: -236), radius: 450)
let rim = NSBezierPath(roundedRect: NSRect(x: -340.5, y: -285.78, width: 681, height: 571.56), xRadius: 258.42, yRadius: 258.42)
rim.lineWidth = 3
color(0xe5ffb2, alpha: 0.35).setStroke()
rim.stroke()
NSGraphicsContext.restoreGraphicsState()
for x: CGFloat in [-119.7, 61.56] {
    color(0xe8ffb8, alpha: 0.45).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: -40.3, width: 58.14, height: 129.96), xRadius: 29.07, yRadius: 29.07).fill()
    let eye = NSBezierPath(roundedRect: NSRect(x: x, y: -37.62, width: 58.14, height: 129.96), xRadius: 29.07, yRadius: 29.07)
    NSGradient(starting: color(0x15251b), ending: color(0x354730))!.draw(in: eye, angle: -90)
    color(0x3c6538, alpha: 0.35).setStroke()
    eye.lineWidth = 2.2
    eye.stroke()
    color(0xe5f2c9, alpha: 0.17).setFill()
    NSBezierPath(ovalIn: NSRect(x: x + 11.2, y: 56.5, width: 14.9, height: 23.8)).fill()
}
let smile = NSBezierPath()
smile.move(to: NSPoint(x: -54.72, y: -129.96))
smile.curve(to: NSPoint(x: 54.72, y: -129.96), controlPoint1: NSPoint(x: -18.24, y: -144.55), controlPoint2: NSPoint(x: 18.24, y: -144.55))
smile.lineWidth = 23.94
smile.lineCapStyle = .round
let smileRim = smile.copy() as! NSBezierPath
let smileInset = NSAffineTransform()
smileInset.translateX(by: 0, yBy: -3)
smileRim.transform(using: smileInset as AffineTransform)
color(0xd9f6a0, alpha: 0.48).setStroke()
smileRim.stroke()
color(0x34532b).setStroke()
smile.stroke()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
