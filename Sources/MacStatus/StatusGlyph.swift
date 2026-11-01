import AppKit

// Shared gauge geometry for template images and fixed menu bar content.
enum StatusGlyph {
    static let header = image(size: 27)
    static func draw(in rect: NSRect, color: NSColor) {
        let scale = rect.width / 18
        let center = NSPoint(x: rect.midX, y: rect.minY + 8.5 * scale)
        color.setStroke()
        color.setFill()
        let rim = NSBezierPath()
        rim.lineWidth = 1.7 * scale
        rim.lineCapStyle = .round
        rim.appendArc(withCenter: center, radius: 6.6 * scale, startAngle: 220, endAngle: -40, clockwise: true)
        rim.stroke()
        let needle = NSBezierPath()
        needle.lineWidth = 1.7 * scale
        needle.lineCapStyle = .round
        needle.move(to: center)
        needle.line(to: NSPoint(x: center.x + 3.7 * scale, y: center.y + 3.7 * scale))
        needle.stroke()
        NSBezierPath(ovalIn: NSRect(x: center.x - 1.35 * scale, y: center.y - 1.35 * scale, width: 2.7 * scale, height: 2.7 * scale)).fill()
        let base = NSBezierPath()
        base.lineWidth = 1.7 * scale
        base.lineCapStyle = .round
        base.move(to: NSPoint(x: center.x - 2.2 * scale, y: center.y - 5.8 * scale))
        base.line(to: NSPoint(x: center.x + 2.2 * scale, y: center.y - 5.8 * scale))
        base.stroke()
    }
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacStatus 系统监控"
        return image
    }

    static func writeAppIcon(to path: String) throws {
        var chunks = Data()
        func bigEndian(_ value: UInt32) -> Data {
            var number = value.bigEndian
            return withUnsafeBytes(of: &number) { Data($0) }
        }
        for (size, kind) in [(32, "icp5"), (64, "icp6"), (128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let width = CGFloat(size)
            let rect = NSRect(x: width * 0.08, y: width * 0.08, width: width * 0.84, height: width * 0.84)
            let rounded = NSBezierPath(roundedRect: rect, xRadius: width * 0.19, yRadius: width * 0.19)
            NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.63, blue: 0.94, alpha: 1),
                       ending: NSColor(calibratedRed: 0.18, green: 0.32, blue: 0.78, alpha: 1))!.draw(in: rounded, angle: -75)
            draw(in: NSRect(x: width * 0.19, y: width * 0.19, width: width * 0.62, height: width * 0.62), color: .white)
            NSGraphicsContext.restoreGraphicsState()
            let png = bitmap.representation(using: .png, properties: [:])!
            chunks.append(Data(kind.utf8))
            chunks.append(bigEndian(UInt32(png.count + 8)))
            chunks.append(png)
        }
        var icon = Data("icns".utf8)
        icon.append(bigEndian(UInt32(chunks.count + 8)))
        icon.append(chunks)
        try icon.write(to: URL(fileURLWithPath: path))
    }
}
