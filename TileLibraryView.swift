import SwiftUI
import UniformTypeIdentifiers

struct TileLibraryView: View {
    struct LibraryItem: Identifiable, Hashable {
        var id = UUID()
        var name: String
        var iconSystemName: String
        var subtitle: String
        var payloadData: Data // serialized drag payload
    }

    private let tiles: [LibraryItem] = {
        let safariPayload = "app:com.apple.Safari".data(using: .utf8)!
        let applePayload = "website:https://apple.com".data(using: .utf8)!
        let keepAwakePayload = "system:keepAwake".data(using: .utf8)!
        return [
            LibraryItem(name: "Safari", iconSystemName: "safari", subtitle: "com.apple.Safari", payloadData: safariPayload),
            LibraryItem(name: "Apple", iconSystemName: "applelogo", subtitle: "https://apple.com", payloadData: applePayload),
            LibraryItem(name: "Keep Awake", iconSystemName: "bolt.fill", subtitle: "System • Keep Awake", payloadData: keepAwakePayload)
        ]
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .imageScale(.medium)
                Text("Tile Library")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            List(tiles) { item in
                LibraryRow(item: item)
                    .onDrag {
                        let provider = NSItemProvider()
                        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
                            completion(self.makeDragData(for: item), nil)
                            return nil
                        }
                        return provider
                    }
            }
            .listStyle(.inset)
        }
    }

    private func makeDragData(for item: LibraryItem) -> Data {
        return item.payloadData
    }
}

private struct LibraryRow: View {
    let item: TileLibraryView.LibraryItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.iconSystemName)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.primary)
            VStack(alignment: .leading) {
                Text(item.name)
                    .font(.body)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    TileLibraryView()
        .frame(width: 320, height: 400)
        .padding()
}
