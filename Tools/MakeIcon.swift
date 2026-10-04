import AppKit

/// Writes the light app icon as a .iconset directory, the PNG sizes `iconutil`
/// turns into the bundle's AppIcon.icns. Built and run by the Makefile, from
/// the same drawing the app uses for its Dock icon (Sources/AppIcon.swift).
@main
struct MakeIcon {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: make-icon <directory.iconset>\n", stderr)
            exit(2)
        }
        guard let source = AppIcon.cgImage(dark: false) else {
            fputs("make-icon: could not draw the icon\n", stderr)
            exit(1)
        }
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for points in [16, 32, 128, 256, 512] {
                try write(source, pixels: points, to: dir.appendingPathComponent("icon_\(points)x\(points).png"))
                try write(source, pixels: points * 2, to: dir.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
            }
        } catch {
            fputs("make-icon: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    /// Scales the 1024-pixel drawing down to one icon size and saves it as PNG.
    static func write(_ image: CGImage, pixels: Int, to url: URL) throws {
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let scaled = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
