import AppKit
import Testing

@testable import FtopUI

/// Writes the app icon as an `.iconset` folder; `scripts/icon.sh` turns it into
/// `Support/AppIcon.icns`. Runs only when asked:
///
///     FTOP_ICON_DIR=/tmp/AppIcon.iconset swift test --filter IconTests
private let iconDirectory = ProcessInfo.processInfo.environment["FTOP_ICON_DIR"]
/// Isolated DNS-badge references, including an enlarged view of the same vector:
/// `FTOP_GLYPH_DIR=/tmp/ftop-glyphs swift test --filter IconTests/writeDNSGlyphImages`
private let glyphDirectory = ProcessInfo.processInfo.environment["FTOP_GLYPH_DIR"]

@MainActor
@Suite struct IconTests {
    @Test func dnsGlyphKeepsThreeEndpointsAndAnOpenResolverAtBadgeSize() throws {
        #expect(Glyph.dns.symbol == nil)
        let glyphSide = PanelStyle().badgeGlyph
        let badgeSide = PanelStyle().badge
        let unit = glyphSide / PanelStyle.glyphExtent
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: badgeSide / 2 + (x - 8) * unit, y: badgeSide / 2 + (y - 8) * unit)
        }
        for scale in [1, 2, 3] as [CGFloat] {
            let (context, image) = try dnsGlyph(scale: scale, dark: false, background: false)
            let ink = try #require(GlyphArt.trimmed(image))
            #expect(CGFloat(ink.width) <= ceil(GlyphArt.inkWidth(.dns, side: glyphSide) * scale) + 2)
            #expect(CGFloat(ink.height) <= ceil(glyphSide * scale) + 2)
            for centerY in [3.5, 8, 12.5] as [CGFloat] {
                #expect(alpha(context, at: point(3.5, centerY), scale: scale) > 128)
            }
            #expect(alpha(context, at: point(11.375, 8), scale: scale) < 64)
        }
    }

    @Test(.enabled(if: glyphDirectory != nil))
    func writeDNSGlyphImages() throws {
        let directory = URL(fileURLWithPath: glyphDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for scale in [1, 2, 8] as [CGFloat] {
                let (_, image) = try dnsGlyph(scale: scale, dark: dark, background: true)
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: directory.appending(path: "dns-badge-\(dark ? "dark" : "light")-\(Int(scale))x.png"))
            }
        }
    }

    @Test(.enabled(if: iconDirectory != nil))
    func writeIconSet() throws {
        let directory = URL(fileURLWithPath: iconDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let image = try #require(Logo.appIcon(pixels: points * scale))
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: directory.appending(path: "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
            }
        }
    }

    private func dnsGlyph(scale: CGFloat, dark: Bool, background: Bool) throws -> (CGContext, CGImage) {
        let side = PanelStyle().badge
        let glyph = PanelStyle().badgeGlyph
        let pixels = Int((side * scale).rounded())
        let context = try #require(
            CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        appearance.performAsCurrentDrawingAppearance {
            if background {
                context.setFillColor(PanelStyle.utilityBackgroundColor.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                context.setFillColor(PanelStyle.badgeColor.cgColor)
                context.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            GlyphArt.draw(
                .dns, in: CGRect(x: (side - glyph) / 2, y: (side - glyph) / 2, width: glyph, height: glyph), color: PanelStyle.inkColor.cgColor, context: context)
        }
        return (context, try #require(context.makeImage()))
    }

    private func alpha(_ context: CGContext, at point: CGPoint, scale: CGFloat) -> UInt8 {
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let x = min(context.width - 1, max(0, Int(floor(point.x * scale))))
        let y = min(context.height - 1, max(0, Int(floor(point.y * scale))))
        return bytes[y * context.bytesPerRow + x * 4 + 3]
    }
}
