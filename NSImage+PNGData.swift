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
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(origin: .zero, size: size),
             from: .zero,
             operation: .copy,
             fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
