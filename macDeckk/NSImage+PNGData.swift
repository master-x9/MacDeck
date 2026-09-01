//
//  NSImage+PNGData.swift
//  PhoneDeck (macOS Host)
//
//  Converts an NSImage to 128×128 PNG Data suitable for storing on
//  DeckTile.iconData and serializing over the WebSocket wire.
//

import AppKit

extension NSImage {

    /// Renders the image into a 128×128 bitmap and returns PNG-encoded `Data`.
    ///
    /// This is the conversion step between `NSWorkspace.shared.icon(forFile:)`
    /// (which returns `NSImage`) and `DeckTile.iconData` (which is `Data?`).
    /// Doing the render once at assignment time avoids image work on every sync.
    func pngData(size: CGSize = CGSize(width: 128, height: 128)) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        context.imageInterpolation = .high
        NSGraphicsContext.current = context
        draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: self.size),
            operation: .sourceOver,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
    
    /// Generates a white-tinted PNG data payload from an SF Symbol name.
    /// This is used to force the iOS app to render specific macOS symbols (like keyboard brightness or Mac lock icons)
    /// instead of falling back to its own hardcoded generic symbols.
    static func sfSymbolPNGData(named name: String, pointSize: CGFloat = 60, weight: NSFont.Weight = .light) -> Data? {
        let size = CGSize(width: 128, height: 128)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        
        let finalImage = NSImage(size: size, flipped: false) { bounds in
            let imageSize = image.size
            let targetRect = NSRect(
                x: (size.width - imageSize.width) / 2.0,
                y: (size.height - imageSize.height) / 2.0,
                width: imageSize.width,
                height: imageSize.height
            )

            // Setting `isTemplate` alone does nothing during a manual draw —
            // template tinting only applies when AppKit itself renders the
            // image (e.g. inside a button). To force solid white here: fill
            // white, then composite the symbol with `.destinationIn`, which
            // keeps only the pixels where the symbol has alpha, filled with
            // that white — i.e. an actual white silhouette of the symbol.
            NSColor.white.set()
            targetRect.fill()
            image.draw(in: targetRect, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }
        
        return finalImage.pngData(size: size)
    }
}
