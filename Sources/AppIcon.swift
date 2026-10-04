import AppKit

/// The app icon: the "i" of ider beside a pair of code brackets, in a light
/// and a dark version.
///
/// It is drawn here rather than kept as an image so there is one drawing to
/// maintain. The running app sets it as the Dock icon and swaps versions with
/// the system appearance; at build time `Tools/MakeIcon.swift` renders the
/// light version into the bundle's AppIcon.icns, which Finder and Launchpad
/// show (a bundle icon cannot follow the appearance). The design is also kept
/// as SVG in `assets/icon/`, in the same 100-unit coordinates as below.
@MainActor
enum AppIcon {
    private static var observation: NSKeyValueObservation?
    private static let light = image(dark: false)
    private static let dark = image(dark: true)

    /// Sets the Dock icon for the current appearance and keeps it in step with
    /// later changes (System Settings › Appearance, including Auto). Call once,
    /// after launch.
    static func install() {
        apply()
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            // AppKit changes the appearance, and so reports it, on the main thread.
            MainActor.assumeIsolated { apply() }
        }
    }

    private static func apply() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = isDark ? dark : light
    }

    static func image(dark: Bool) -> NSImage {
        guard let cgImage = cgImage(dark: dark) else { return NSImage() }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Draws the icon as a 1024-pixel bitmap on Apple's icon grid: an 824-pixel
    /// rounded square centred on the canvas, the margin left for the shadow, so
    /// it sits at the same size as the other icons in the Dock and in Finder.
    static func cgImage(dark: Bool) -> CGImage? {
        let size = 1024
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // The design's coordinates run 0–100 with y pointing down, as in the SVG.
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 100, y: 100)
        ctx.scaleBy(x: 8.24, y: 8.24)

        let tile = dark ? rgb(0x131418) : rgb(0xF7F4EC)
        let border = dark ? rgb(0x2A2C33) : rgb(0xDCD8CE)
        let stem = dark ? rgb(0xFFFFFF) : rgb(0x17181C)
        let accent = rgb(0x12A37F)

        // Tile, with a soft drop shadow. A shadow's offset is in device space,
        // which the flip above does not touch, so a negative height is downward.
        let tilePath = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 99, height: 99),
                              cornerWidth: 22, cornerHeight: 22, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                      color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(tilePath)
        ctx.setFillColor(tile)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(tilePath)
        ctx.setStrokeColor(border)
        ctx.setLineWidth(1)
        ctx.strokePath()

        // The "i": accent dot over a rounded stem.
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: CGRect(x: 23.5, y: 20.5, width: 15, height: 15))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 24.5, y: 42, width: 13, height: 34),
                           cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
        ctx.setFillColor(stem)
        ctx.fillPath()

        // Code brackets, < >, as round-capped strokes.
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for points in [[(57, 46), (49, 59), (57, 72)], [(67, 46), (75, 59), (67, 72)]] {
            ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
            ctx.strokePath()
        }

        return ctx.makeImage()
    }

    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
