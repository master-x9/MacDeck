import Foundation
import AppKit

// Namespace to avoid type name collisions with app models
enum ResizeScriptModels {
    // Lightweight Codable wrapper for heterogeneous JSON values
    fileprivate struct AnyCodable: Codable {
        let value: Any
        
        init(_ value: Any) { self.value = value }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intVal = try? container.decode(Int.self) { value = intVal }
            else if let doubleVal = try? container.decode(Double.self) { value = doubleVal }
            else if let boolVal = try? container.decode(Bool.self) { value = boolVal }
            else if let stringVal = try? container.decode(String.self) { value = stringVal }
            else if let arrayVal = try? container.decode([AnyCodable].self) { value = arrayVal.map { $0.value } }
            else if let dictVal = try? container.decode([String: AnyCodable].self) { value = dictVal.mapValues { $0.value } }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown type") }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let intVal = value as? Int { try container.encode(intVal) }
            else if let doubleVal = value as? Double { try container.encode(doubleVal) }
            else if let boolVal = value as? Bool { try container.encode(boolVal) }
            else if let stringVal = value as? String { try container.encode(stringVal) }
            else if let arrayVal = value as? [Any] { try container.encode(arrayVal.map { AnyCodable($0) }) }
            else if let dictVal = value as? [String: Any] { try container.encode(dictVal.mapValues { AnyCodable($0) }) }
            else { try container.encodeNil() }
        }
    }
    
    // Local copy of the deck tile used only by this script
    fileprivate struct ResizeScriptDeckTile: Codable {
        var id: String?
        var slotIndex: Int
        var tileType: [String: Any]?
        var iconData: String?
        
        enum CodingKeys: String, CodingKey { case id, slotIndex, tileType, iconData }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            slotIndex = try container.decode(Int.self, forKey: .slotIndex)
            iconData = try container.decodeIfPresent(String.self, forKey: .iconData)
            
            if let typeContainer = try? container.decode([String: AnyCodable].self, forKey: .tileType) {
                tileType = typeContainer.mapValues { $0.value }
            } else {
                tileType = nil
            }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(slotIndex, forKey: .slotIndex)
            try container.encodeIfPresent(iconData, forKey: .iconData)
            if let tileType = tileType {
                let encodableType = tileType.mapValues { AnyCodable($0) }
                try container.encode(encodableType, forKey: .tileType)
            }
        }
    }
    
    // Local copy of the deck page used only by this script
    fileprivate struct ResizeScriptDeckPage: Codable {
        var id: String
        var pageNumber: Int
        var name: String?
        var tiles: [ResizeScriptDeckTile?]
    }
}

private func resizeImage(data: Data, size: CGSize = CGSize(width: 128, height: 128)) -> Data? {
    guard let image = NSImage(data: data) else { return nil }
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
    image.draw(
        in: NSRect(origin: .zero, size: size),
        from: NSRect(origin: .zero, size: image.size),
        operation: .sourceOver,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func resizeAllIconsInPagesJSON() {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("PhoneDeck", isDirectory: true)
    let url = dir.appendingPathComponent("pages.json")

    guard FileManager.default.fileExists(atPath: url.path) else {
        print("pages.json not found at \(url.path). Nothing to resize.")
        return
    }

    do {
        let data = try Data(contentsOf: url)
        var pages = try JSONDecoder().decode([ResizeScriptModels.ResizeScriptDeckPage].self, from: data)

        var resizedCount = 0
        for i in 0..<pages.count {
            for j in 0..<pages[i].tiles.count {
                if var tile = pages[i].tiles[j], let base64 = tile.iconData, let imgData = Data(base64Encoded: base64) {
                    if imgData.count > 10000 { // If larger than ~10KB, resize it
                        if let resized = resizeImage(data: imgData) {
                            tile.iconData = resized.base64EncodedString()
                            pages[i].tiles[j] = tile
                            resizedCount += 1
                        }
                    }
                }
            }
        }

        let newData = try JSONEncoder().encode(pages)
        try newData.write(to: url)
        print("Successfully resized \(resizedCount) icons in pages.json. Old size: \(data.count) bytes, New size: \(newData.count) bytes")
    } catch {
        print("Error: \(error)")
    }
}

// To avoid conflicts with the main app target, gate the script's entry point behind a custom flag.
#if DEBUG && RESIZE_SCRIPT
@main
struct ResizeScriptMain {
    static func main() {
        // Only runs if this file is built as a standalone tool or invoked with RESIZE_SCRIPT flag.
        resizeAllIconsInPagesJSON()
    }
}
#endif
