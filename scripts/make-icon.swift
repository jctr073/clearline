import AppKit
import Foundation

// Original Clearline mark: three clear lines, held in an open bracket.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        NSColor(red: 0.08, green: 0.15, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 45, y: 45, width: 934, height: 934), xRadius: 220, yRadius: 220).fill()
        NSColor(red: 0.72, green: 0.88, blue: 0.73, alpha: 1).setStroke()
        let bracket = NSBezierPath(); bracket.lineWidth = 48; bracket.lineCapStyle = .round; bracket.lineJoinStyle = .round
        bracket.move(to: NSPoint(x: 690, y: 758)); bracket.line(to: NSPoint(x: 310, y: 758)); bracket.curve(to: NSPoint(x: 230, y: 678), controlPoint1: NSPoint(x: 255, y: 758), controlPoint2: NSPoint(x: 230, y: 725))
        bracket.line(to: NSPoint(x: 230, y: 346)); bracket.curve(to: NSPoint(x: 310, y: 266), controlPoint1: NSPoint(x: 230, y: 299), controlPoint2: NSPoint(x: 255, y: 266)); bracket.line(to: NSPoint(x: 550, y: 266)); bracket.stroke()
        for (y, end) in [(622, 765), (510, 680), (398, 595)] {
            let line = NSBezierPath(); line.lineWidth = 45; line.lineCapStyle = .round
            line.move(to: NSPoint(x: 360, y: y)); line.line(to: NSPoint(x: end, y: y)); line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
