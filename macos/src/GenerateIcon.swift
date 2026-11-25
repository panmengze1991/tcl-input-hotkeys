import AppKit

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let tile = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840), xRadius: 190, yRadius: 190)
NSGradient(starting: NSColor(srgbRed: 0.14, green: 0.35, blue: 0.87, alpha: 1),
           ending: NSColor(srgbRed: 0.11, green: 0.17, blue: 0.43, alpha: 1))!.draw(in: tile, angle: -45)

NSColor.white.setStroke()
let screen = NSBezierPath(roundedRect: NSRect(x: 247, y: 358, width: 530, height: 353), xRadius: 62, yRadius: 62)
screen.lineWidth = 32
screen.stroke()
let stand = NSBezierPath()
stand.lineWidth = 28
stand.lineCapStyle = .round
stand.move(to: NSPoint(x: 512, y: 358))
stand.line(to: NSPoint(x: 512, y: 281))
stand.move(to: NSPoint(x: 420, y: 281))
stand.line(to: NSPoint(x: 604, y: 281))
stand.stroke()

NSColor(srgbRed: 0.57, green: 0.86, blue: 1, alpha: 1).setFill()
for rect in [NSRect(x: 409, y: 516, width: 206, height: 36), NSRect(x: 494, y: 431, width: 36, height: 206)] {
    NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
