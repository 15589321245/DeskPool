import AppKit
import BilliardsCore

enum Artwork {
    /// Build the outline once from the icon's alpha channel, following its actual silhouette.
    static func outlinedIcon(_ image: NSImage, rgb: (Int, Int, Int) = (105, 255, 169)) -> NSImage {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let side = 128, stride = side * 4
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var pixels = [UInt8](repeating: 0, count: side * stride)
        guard let sourceContext = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                            bytesPerRow: stride, space: space, bitmapInfo: info) else { return image }
        sourceContext.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        var outline = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<side {
            for x in 0..<side {
                var alpha: UInt8 = 0
                for dy in -3...3 {
                    for dx in -3...3 where dx * dx + dy * dy <= 9 {
                        let px = x + dx, py = y + dy
                        if px >= 0 && px < side && py >= 0 && py < side {
                            alpha = max(alpha, pixels[py * stride + px * 4 + 3])
                        }
                    }
                }
                let a = Int(alpha) * 220 / 255, index = y * stride + x * 4
                outline[index] = UInt8(rgb.0 * a / 255)
                outline[index + 1] = UInt8(rgb.1 * a / 255)
                outline[index + 2] = UInt8(rgb.2 * a / 255)
                outline[index + 3] = UInt8(a)
            }
        }
        guard let context = CGContext(data: &outline, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: stride, space: space, bitmapInfo: info) else { return image }
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let result = context.makeImage() else { return image }
        return NSImage(cgImage: result, size: image.size)
    }
    static func cachedIcon(_ image: NSImage) -> NSImage {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        guard let bitmap = context.makeImage() else { return image }
        return NSImage(cgImage: bitmap, size: image.size)
    }
    static func color(_ r: Int, _ g: Int, _ b: Int, _ a: Int = 255) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
                alpha: CGFloat(a) / 255)
    }

    /// Transparent table markings and faint pockets, baked once.
    static func tableBackground(size: CGSize, scale: CGFloat, table: BilliardsMotion) -> NSImage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        let h = size.height
        func rect(_ x: Double, _ y: Double, _ w: Double, _ hh: Double) -> CGRect {
            CGRect(x: x, y: h - y - hh, width: w, height: hh)
        }
        func point(_ v: V2) -> CGPoint { CGPoint(x: v.x, y: h - v.y) }

        let bounds = table.bounds
        let feltRect = rect(bounds.left, bounds.top, bounds.width, bounds.height)
        context.setStrokeColor(color(105, 221, 179, 30).cgColor)
        context.setLineWidth(1)
        context.stroke(feltRect.insetBy(dx: 1.5, dy: 1.5))

        let r = table.pocketRadius.rounded()
        for pocket in table.pockets {
            let center = point(pocket)
            let outer = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            context.setFillColor(color(4, 10, 11, 65).cgColor)
            context.fillEllipse(in: outer)
            context.setStrokeColor(color(105, 221, 179, 110).cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: outer.insetBy(dx: 1, dy: 1))
        }
        return NSImage(cgImage: context.makeImage()!, size: size)
    }

    /// The cue ball as a lit sphere, port of the Windows edition's shaded white art.
    static func cueBall(radius: Double) -> NSImage {
        let side = max(3, Int((radius * 2).rounded(.up)) + 4)
        let big = side * 3
        var pixels = [UInt8](repeating: 0, count: big * big * 4)
        let center = Double(big - 1) / 2
        let r = max(1, radius * 3)
        for py in 0..<big {
            let y = (Double(py) - center) / r
            for px in 0..<big {
                let x = (Double(px) - center) / r
                let z2 = 1 - x * x - y * y
                let offset = (py * big + px) * 4
                if z2 < 0 { continue }
                let z = z2.squareRoot()
                let light = max(0, -0.46 * x - 0.49 * y + 0.74 * z)
                let shine = exp(-((x + 0.34) * (x + 0.34) + (y + 0.40) * (y + 0.40)) / 0.038)
                let value = min(255, (157 + 96 * light + 32 * shine).rounded())
                pixels[offset] = UInt8(value)
                pixels[offset + 1] = UInt8(min(255, value + 4))
                pixels[offset + 2] = UInt8(min(255, value + 9))
                pixels[offset + 3] = 255
            }
        }
        let source = CGContext(data: &pixels, width: big, height: big, bitsPerComponent: 8,
                               bytesPerRow: big * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let target = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        target.interpolationQuality = .high
        target.draw(source.makeImage()!, in: CGRect(x: 0, y: 0, width: side, height: side))
        return NSImage(cgImage: target.makeImage()!, size: CGSize(width: side, height: side))
    }
}
