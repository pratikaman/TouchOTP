import AppKit

// Original vector artwork; no downloaded images or account data.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(size: Int, name: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.1, green: 0.27, blue: 0.61, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.15, green: 0.49, blue: 0.92, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.70, alpha: 1))!
        .draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.17).setStroke()
    tile.lineWidth = 2; tile.stroke()
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    cg.setLineWidth(32); cg.setLineCap(.round); cg.setLineJoin(.round)
    func stroke(_ start: CGPoint, _ curves: [(CGPoint, CGPoint, CGPoint)]) {
        cg.beginPath(); cg.move(to: start)
        for (a, b, end) in curves { cg.addCurve(to: end, control1: a, control2: b) }
        cg.strokePath()
    }
    stroke(CGPoint(x: 259, y: 410), [(CGPoint(x: 235, y: 670), CGPoint(x: 339, y: 767), CGPoint(x: 513, y: 770)),
                                    (CGPoint(x: 676, y: 772), CGPoint(x: 779, y: 652), CGPoint(x: 762, y: 479))])
    stroke(CGPoint(x: 306, y: 312), [(CGPoint(x: 352, y: 414), CGPoint(x: 308, y: 462), CGPoint(x: 332, y: 568)),
                                    (CGPoint(x: 355, y: 699), CGPoint(x: 504, y: 735), CGPoint(x: 600, y: 672)),
                                    (CGPoint(x: 710, y: 604), CGPoint(x: 693, y: 524), CGPoint(x: 696, y: 433))])
    stroke(CGPoint(x: 382, y: 268), [(CGPoint(x: 446, y: 382), CGPoint(x: 382, y: 452), CGPoint(x: 409, y: 556)),
                                    (CGPoint(x: 432, y: 648), CGPoint(x: 551, y: 653), CGPoint(x: 600, y: 577)),
                                    (CGPoint(x: 646, y: 505), CGPoint(x: 596, y: 417), CGPoint(x: 657, y: 318))])
    stroke(CGPoint(x: 474, y: 257), [(CGPoint(x: 534, y: 381), CGPoint(x: 472, y: 463), CGPoint(x: 483, y: 533)),
                                    (CGPoint(x: 490, y: 577), CGPoint(x: 548, y: 579), CGPoint(x: 550, y: 530)),
                                    (CGPoint(x: 548, y: 430), CGPoint(x: 555, y: 342), CGPoint(x: 583, y: 273))])
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}
for points in [16, 32, 128, 256, 512] {
    try drawIcon(size: points, name: "icon_\(points)x\(points).png")
    try drawIcon(size: points * 2, name: "icon_\(points)x\(points)@2x.png")
}
