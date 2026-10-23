import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let edge = CGFloat(size)
        let inset = edge * 0.045
        let room = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: edge - 2 * inset,
            height: edge - 2 * inset), xRadius: edge * 0.22, yRadius: edge * 0.22)
        NSColor(srgbRed: 0.102, green: 0.092, blue: 0.075, alpha: 1).setFill()
        room.fill()
        NSColor(srgbRed: 0.72, green: 0.56, blue: 0.36, alpha: 0.28).setStroke()
        room.lineWidth = max(1, edge * 0.004)
        room.stroke()
        let font = NSFont(name: "Iowan Old Style", size: edge * 0.65) ?? NSFont(name: "Baskerville", size: edge * 0.65)!
        let text: NSString = "s"
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
            .foregroundColor: NSColor(srgbRed: 0.87, green: 0.82, blue: 0.72, alpha: 1)]
        let measure = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: edge * 0.45 - measure.width * 0.5,
                              y: edge * 0.47 - measure.height * 0.5), withAttributes: attributes)
        NSColor(srgbRed: 0.79, green: 0.63, blue: 0.44, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: edge * 0.65, y: edge * 0.28,
                                   width: edge * 0.055, height: edge * 0.055)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(base)x\(base)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
