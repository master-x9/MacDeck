//
//  PhoneFrameGridView.swift
//  MacDeck (macOS Host)
//
//  A precision hardware deck / phone screen preview containing the live 2×5 grid.
//  Provides tactile keycaps, instant drag-and-drop feedback, live drop targeting,
//  subtle wobble edit physics, and inspector popovers.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum TileImageCache {
    private static let cache = NSCache<NSData, NSImage>()

    static func image(for data: Data) -> NSImage? {
        let nsData = data as NSData
        if let cached = cache.object(forKey: nsData) {
            return cached
        }
        if let img = NSImage(data: data) {
            cache.setObject(img, forKey: nsData)
            return img
        }
        return nil
    }
}

struct PhoneFrameGridView: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    @Binding var selectedSlot: Int?
    @Binding var showingLibrary: Bool

    @State private var editingTileSlot: Int? = nil
    @State private var showingTilePopover = false
    @State private var isEditModeActive = false
    @State private var tilesBackup: [Int: DeckTile]? = nil

    private let columns = [
        GridItem(.fixed(88), spacing: 14),
        GridItem(.fixed(88), spacing: 14),
        GridItem(.fixed(88), spacing: 14),
        GridItem(.fixed(88), spacing: 14),
        GridItem(.fixed(88), spacing: 14)
    ]

    private var statusColor: Color {
        switch network.status {
        case .disconnected: return .red
        case .waiting, .awaitingHello, .awaitingApproval: return .orange
        case .connected: return .green
        }
    }

    var body: some View {
        ZStack {
            // 1. Precision Anodized Aluminum Outer Bezel & Chassis
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.16),
                            Color(white: 0.09),
                            Color(white: 0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    // Precision chamfered metallic edge highlight
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.25),
                                    Color.white.opacity(0.08),
                                    Color.black.opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
                .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)

            // 2. Inner Edge-to-Edge OLED Glass Screen Area
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(white: 0.04))
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.black.opacity(0.8), lineWidth: 1)
                        .padding(4)
                )

            // 3. Screen Elements (Dynamic Island, Home Bar, Live Grid)
            ZStack {
                // A. Left Side: Dynamic Island Accent
                HStack {
                    Capsule()
                        .fill(Color.black)
                        .frame(width: 14, height: 56)
                        .overlay(
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 6, height: 6)
                                .padding(.top, 8),
                            alignment: .top
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
                        )
                        .padding(.leading, 12)
                    Spacer()
                }

                // B. Right Side: Home Indicator Bar
                HStack {
                    Spacer()
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 4, height: 96)
                        .padding(.trailing, 12)
                }

                // C. Main 2×5 Grid Viewport
                ZStack {
                    if let activePage = store.activePage {
                        let isRunningApps = activePage.id == RunningAppsMonitor.runningAppsPageID
                        let tileCount = isRunningApps ? activePage.tiles.count : store.gridRows * 5

                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(0..<tileCount, id: \.self) { index in
                                    DeckSlotView(
                                        index: index,
                                        tile: index < activePage.tiles.count ? activePage.tiles[index] : nil,
                                        isSelected: selectedSlot == index,
                                        isEditModeActive: isEditModeActive,
                                        isRunningApps: isRunningApps,
                                        onSelectSlot: {
                                            withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                                                selectedSlot = index
                                                showingLibrary = true
                                            }
                                        },
                                        onTileTapped: { tile in
                                            if isRunningApps {
                                                SystemActionEngine.shared.execute(tile.tileType)
                                            } else if !isEditModeActive {
                                                editingTileSlot = index
                                                showingTilePopover = true
                                            }
                                        },
                                        onRemove: {
                                            withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                                                store.removeTile(atSlot: index) {
                                                    network.broadcastPageUpdate()
                                                }
                                            }
                                        },
                                        onDropPayload: { payload in
                                            handleDropPayload(payload, into: index)
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 40)
                            .padding(.vertical, 32)
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("No Active Page")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Bottom Overlay: Status Light & Page Switcher Dots
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            // Left Status Light
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 7, height: 7)
                                    .shadow(color: statusColor.opacity(0.8), radius: 3)

                                Text({ if case .connected = network.status { return "Live" } else { return "Deck" } }())
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 32)

                            Spacer()

                            // Center Page Pills
                            HStack(spacing: 6) {
                                ForEach(store.pages) { page in
                                    if page.id == store.selectedPageID {
                                        Capsule()
                                            .fill(Color.white)
                                            .frame(width: 16, height: 4)
                                            .shadow(color: Color.white.opacity(0.6), radius: 3)
                                    } else {
                                        Circle()
                                            .fill(Color.white.opacity(0.25))
                                            .frame(width: 4, height: 4)
                                            .onTapGesture {
                                                if !isEditModeActive {
                                                    withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                                                        store.selectedPageID = page.id
                                                    }
                                                }
                                            }
                                    }
                                }
                            }

                            Spacer()

                            // Right Spacer for symmetry
                            Color.clear
                                .frame(width: 60, height: 1)
                                .padding(.trailing, 32)
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .colorScheme(.dark)
        .frame(width: 590, height: 285 + CGFloat((store.gridRows - 2) * 102))
        .fixedSize()
        .popover(isPresented: $showingTilePopover, arrowEdge: .bottom) {
            if let slot = editingTileSlot, let tile = store.activePage?.tiles[slot] {
                TileInspectorPopover(tile: tile, slotIndex: slot)
                    .environmentObject(store)
                    .environmentObject(network)
                    .frame(width: 290)
            }
        }
    }

    private func handleDropPayload(_ payload: DragTilePayload, into slot: Int) {
        switch payload.kind {
        case .app:
            guard let bundleID = payload.bundleID, let name = payload.appName else { return }
            let appIcon: NSImage = AppsCache.shared.apps.first(where: { $0.bundleID == bundleID })?.icon ?? {
                let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? ""
                return path.isEmpty ? NSImage() : NSWorkspace.shared.icon(forFile: path)
            }()
            store.assignAppTile(bundleID: bundleID, name: name, icon: appIcon, toSlot: slot) {
                network.broadcastPageUpdate()
            }
        case .control:
            guard let action = payload.control else { return }
            let tile = DeckTile(slotIndex: slot, tileType: .systemControl(action: action))
            store.assignTile(tile, toSlot: slot) {
                network.broadcastPageUpdate()
            }
        case .website:
            guard let url = payload.url else { return }
            let name = payload.websiteName ?? url
            let cached = WebsiteIconLoader.cachedIconData(for: url)
            let tile = DeckTile(slotIndex: slot, tileType: .website(url: url, name: name), iconData: cached)
            store.assignTile(tile, toSlot: slot) {
                network.broadcastPageUpdate()
            }
        case .existingTile:
            guard let sourceSlot = payload.sourceSlot else { return }
            store.moveTile(from: sourceSlot, to: slot) {
                if !isEditModeActive {
                    network.broadcastPageUpdate()
                }
            }
        case .shortcut:
            guard let name = payload.shortcutName else { return }
            let tile = DeckTile(slotIndex: slot, tileType: .shortcut(name: name))
            store.assignTile(tile, toSlot: slot) {
                network.broadcastPageUpdate()
            }
        }
    }
}

// MARK: - Individual Deck Slot View (Keycap + Drop Target)

private struct DeckSlotView: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    let index: Int
    let tile: DeckTile?
    let isSelected: Bool
    let isEditModeActive: Bool
    let isRunningApps: Bool

    let onSelectSlot: () -> Void
    let onTileTapped: (DeckTile) -> Void
    let onRemove: () -> Void
    let onDropPayload: (DragTilePayload) -> Void

    @State private var isTargeted = false
    @State private var isHovered = false
    @State private var showingIconCustomizer = false
    @State private var wiggleAngle = Angle.degrees(0)

    private var isControl: Bool {
        guard let tile else { return false }
        switch tile.tileType {
        case .systemControl, .browserControl: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            if let tile {
                // Occupied Keycap Tile
                ZStack {
                    VStack(spacing: 4) {
                        // Keycap Icon
                        keycapIcon(for: tile)
                            .frame(width: 44, height: 44)

                        // Keycap Label
                        Text(tile.label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 76)
                    }
                    .frame(width: 88, height: 88)
                    .keycapSurface(
                        isHovered: isHovered,
                        isTargeted: isTargeted,
                        isSelected: isSelected,
                        isControl: isControl
                    )
                    .scaleEffect(isEditModeActive ? 1.04 : (isTargeted ? 1.08 : (isHovered ? 1.03 : 1.0)))
                    .rotationEffect(wiggleAngle)

                    // Edit Mode Badges (Pencil on top-left, Minus on top-right)
                    if (isHovered || showingIconCustomizer || isEditModeActive) && !isRunningApps {
                        VStack {
                            HStack {
                                // Top-Left Customize Icon Button
                                Button {
                                    showingIconCustomizer = true
                                } label: {
                                    Image(systemName: "pencil.circle.fill")
                                        .font(.system(size: 18, weight: .bold))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(Color.white, Color.accentColor)
                                        .shadow(color: Color.black.opacity(0.5), radius: 3, y: 1)
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                // Top-Right Remove Button
                                Button {
                                    onRemove()
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 18, weight: .bold))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(Color.white, Color.red)
                                        .shadow(color: Color.black.opacity(0.5), radius: 3, y: 1)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(4)
                            Spacer()
                        }
                        .transition(.opacity)
                    }
                }
                .popover(isPresented: $showingIconCustomizer, arrowEdge: .top) {
                    IconCustomizerSheet(tile: tile, slotIndex: index)
                        .environmentObject(store)
                        .environmentObject(network)
                }
                .onTapGesture {
                    onTileTapped(tile)
                }
                .onDrag {
                    if !isRunningApps {
                        let payload = DragTilePayload(
                            kind: .existingTile,
                            bundleID: nil,
                            appName: nil,
                            control: nil,
                            url: nil,
                            websiteName: nil,
                            shortcutName: nil,
                            sourceSlot: index
                        )
                        if let data = try? JSONEncoder().encode(payload) {
                            return NSItemProvider(item: data as NSData, typeIdentifier: UTType.data.identifier)
                        }
                    }
                    return NSItemProvider()
                }
                .contextMenu {
                    if !isRunningApps {
                        Button {
                            showingIconCustomizer = true
                        } label: {
                            Label("Customize Icon", systemImage: "paintbrush")
                        }

                        Divider()

                        Button(role: .destructive) {
                            onRemove()
                        } label: {
                            Label("Remove Tile", systemImage: "trash")
                        }
                    }
                }
            } else if !isRunningApps {
                EmptyDeckSlotKeycapView(
                    isSelected: isSelected,
                    isTargeted: isTargeted,
                    isHovered: isHovered,
                    onSelectSlot: onSelectSlot
                )
            }
        }
        .frame(width: 88, height: 88)
        .animation(.spring(response: 0.15, dampingFraction: 0.8), value: isHovered)
        .animation(.spring(response: 0.15, dampingFraction: 0.8), value: isTargeted)
        .animation(.spring(response: 0.15, dampingFraction: 0.8), value: isEditModeActive)
        .onHover { hovering in
            if !isEditModeActive {
                isHovered = hovering
            }
        }
        .onChange(of: isEditModeActive) { _, active in
            if active {
                isHovered = false
                startWiggle()
            } else {
                withAnimation(.linear(duration: 0.1)) {
                    wiggleAngle = .degrees(0)
                }
            }
        }
        .onAppear {
            if isEditModeActive {
                startWiggle()
            }
        }
        // Universal Drop Target
        .onDrop(of: isRunningApps ? [] : [UTType.data.identifier], isTargeted: $isTargeted) { providers in
            guard !isRunningApps, let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.data.identifier) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async {
                    if let payload = try? JSONDecoder().decode(DragTilePayload.self, from: data) {
                        onDropPayload(payload)
                    }
                }
            }
            return true
        }
    }

    private func startWiggle() {
        withAnimation(.easeInOut(duration: 0.12)) {
            wiggleAngle = .degrees(1.2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard isEditModeActive else { return }
            withAnimation(.easeInOut(duration: 0.2).repeatForever(autoreverses: true)) {
                wiggleAngle = .degrees(-1.2)
            }
        }
    }

    @ViewBuilder
    private func keycapIcon(for tile: DeckTile) -> some View {
        if let data = tile.iconData, let nsImage = TileImageCache.image(for: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .cornerRadius(8)
                .shadow(color: Color.black.opacity(0.3), radius: 2, y: 1)
        } else {
            // Authentic Mac laser-etched keyboard symbol look
            ZStack {
                Image(systemName: systemImageName(for: tile.tileType))
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .fontWeight(isControl ? .medium : .regular)
                    .foregroundStyle(Color.white.opacity(0.95))
                    .shadow(color: Color.white.opacity(0.2), radius: 3)
            }
        }
    }

    private func systemImageName(for type: TileType) -> String {
        switch type {
        case .app: return "app.dashed"
        case .website: return "globe"
        case .shortcut: return "bolt.fill"
        case .browserControl(let action):
            switch action {
            case .back: return "arrow.left"
            case .forward: return "arrow.right"
            case .refresh: return "arrow.clockwise"
            case .newTab: return "plus"
            case .closeTab: return "xmark"
            default: return "safari"
            }
        case .systemControl(let action):
            return action.defaultSystemImageName
        case .obsControl(let action):
            return action.defaultSystemImageName
        case .discordControl(let action):
            return action.defaultSystemImageName
        }
    }
}

// MARK: - Empty Deck Slot Keycap View

private struct EmptyDeckSlotKeycapView: View {
    let isSelected: Bool
    let isTargeted: Bool
    let isHovered: Bool
    let onSelectSlot: () -> Void

    private var strokeColor: Color {
        if isTargeted { return Color.accentColor }
        if isSelected { return Color.accentColor.opacity(0.9) }
        if isHovered { return Color.white.opacity(0.35) }
        return Color.white.opacity(0.12)
    }

    private var strokeWidth: CGFloat {
        if isTargeted { return 2.5 }
        if isSelected { return 1.8 }
        return 1.2
    }

    private var dashPattern: [CGFloat] {
        if isTargeted || isSelected { return [] }
        return [5, 4]
    }

    private var fillColor: Color {
        if isTargeted { return Color.accentColor.opacity(0.2) }
        if isHovered { return Color.white.opacity(0.06) }
        return Color.white.opacity(0.02)
    }

    private var shadowColor: Color {
        if isTargeted { return Color.accentColor.opacity(0.6) }
        if isSelected { return Color.accentColor.opacity(0.3) }
        return Color.clear
    }

    private var iconName: String {
        isTargeted ? "arrow.down.circle.fill" : "plus"
    }

    private var iconColor: Color {
        if isTargeted || isSelected { return Color.accentColor }
        if isHovered { return Color.white }
        return Color.white.opacity(0.35)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(strokeColor, style: StrokeStyle(lineWidth: strokeWidth, dash: dashPattern))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(fillColor)
                )
                .shadow(color: shadowColor, radius: isTargeted ? 10 : 4)

            Image(systemName: iconName)
                .font(.system(size: isTargeted ? 24 : 20, weight: .light))
                .foregroundStyle(iconColor)
                .scaleEffect(isHovered ? 1.15 : 1.0)
        }
        .frame(width: 88, height: 88)
        .contentShape(Rectangle())
        .scaleEffect(isTargeted ? 1.06 : (isHovered ? 1.02 : 1.0))
        .onTapGesture {
            onSelectSlot()
        }
    }
}

// MARK: - Tile Inspector Popover

struct TileInspectorPopover: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    let tile: DeckTile
    let slotIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var customLabel: String = ""
    @State private var showingIconCustomizer = false

    var body: some View {
        VStack(spacing: 16) {
            // Header / Preview
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 48, height: 48)

                    if let data = tile.iconData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .cornerRadius(8)
                    } else {
                        Image(systemName: systemImageName(for: tile.tileType))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.label)
                        .font(.headline)
                        .lineLimit(1)
                    Text(tile.tileType.defaultLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            // Rename Field
            HStack {
                TextField("Custom Label", text: $customLabel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        saveLabel()
                    }

                Button("Save") {
                    saveLabel()
                }
                .controlSize(.small)
                .disabled(customLabel.isEmpty || customLabel == tile.label)
            }

            // Quick Actions
            VStack(spacing: 8) {
                Button {
                    showingIconCustomizer = true
                } label: {
                    Label("Change Icon / GIF…", systemImage: "photo")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showingIconCustomizer, arrowEdge: .top) {
                    IconCustomizerSheet(tile: tile, slotIndex: slotIndex)
                        .environmentObject(store)
                        .environmentObject(network)
                }

                Button {
                    store.removeTile(atSlot: slotIndex) {
                        network.broadcastPageUpdate()
                    }
                    dismiss()
                    NotificationCenter.default.post(
                        name: .openTileLibraryForSlot,
                        object: slotIndex
                    )
                } label: {
                    Label("Replace Tile…", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    store.removeTile(atSlot: slotIndex) {
                        network.broadcastPageUpdate()
                    }
                    dismiss()
                } label: {
                    Label("Remove Tile", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .onAppear {
            customLabel = tile.customLabel ?? tile.label
        }
    }

    private func saveLabel() {
        var updated = tile
        updated.customLabel = customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        store.assignTile(updated, toSlot: slotIndex) {
            network.broadcastPageUpdate()
        }
        dismiss()
    }

    private func systemImageName(for type: TileType) -> String {
        switch type {
        case .app: return "app.dashed"
        case .website: return "globe"
        case .shortcut: return "bolt.fill"
        case .browserControl(let action):
            switch action {
            case .back: return "arrow.left"
            case .forward: return "arrow.right"
            case .refresh: return "arrow.clockwise"
            case .newTab: return "plus"
            case .closeTab: return "xmark"
            default: return "safari"
            }
        case .systemControl(let action):
            return action.defaultSystemImageName
        case .obsControl(let action):
            return action.defaultSystemImageName
        case .discordControl(let action):
            return action.defaultSystemImageName
        }
    }
}

// MARK: - Icon Customizer Sheet

struct IconCustomizerSheet: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    let tile: DeckTile
    let slotIndex: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Customize Icon")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 76, height: 76)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )

                if let data = tile.iconData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 54, height: 54)
                        .cornerRadius(10)
                } else {
                    Image(systemName: systemImageName(for: tile.tileType))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .foregroundColor(.white)
                }
            }

            Text(tile.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Divider()

            VStack(spacing: 8) {
                Button {
                    browseCustomIcon()
                } label: {
                    Label("Browse Image or GIF…", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if tile.iconData != nil {
                    Button(role: .destructive) {
                        resetIcon()
                    } label: {
                        Label("Reset Default Icon", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(20)
        .frame(width: 270)
    }

    private func browseCustomIcon() {
        let panel = NSOpenPanel()
        panel.title = "Select Tile Icon or GIF"
        panel.allowedContentTypes = [.image, .gif, .png, .jpeg, .heic, .webP, .svg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            if let data = try? Data(contentsOf: url) {
                var updatedTile = tile
                updatedTile.iconData = data
                store.assignTile(updatedTile, toSlot: slotIndex) {
                    network.broadcastPageUpdate()
                }
                dismiss()
            }
        }
    }

    private func resetIcon() {
        switch tile.tileType {
        case .app(let bundleID, _):
            var updatedTile = tile
            let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? ""
            let appIcon = NSWorkspace.shared.icon(forFile: path)
            updatedTile.iconData = appIcon.pngData(size: CGSize(width: 128, height: 128))
            store.assignTile(updatedTile, toSlot: slotIndex) {
                network.broadcastPageUpdate()
            }
            dismiss()
        case .website(let url, _):
            var updatedTile = tile
            updatedTile.iconData = WebsiteIconLoader.cachedIconData(for: url)
            store.assignTile(updatedTile, toSlot: slotIndex) {
                network.broadcastPageUpdate()
            }
            dismiss()
        default:
            var updatedTile = tile
            updatedTile.iconData = nil
            store.assignTile(updatedTile, toSlot: slotIndex) {
                network.broadcastPageUpdate()
            }
            dismiss()
        }
    }

    private func systemImageName(for type: TileType) -> String {
        switch type {
        case .app: return "app.dashed"
        case .website: return "globe"
        case .shortcut: return "bolt.fill"
        case .browserControl(let action):
            switch action {
            case .back: return "arrow.left"
            case .forward: return "arrow.right"
            case .refresh: return "arrow.clockwise"
            case .newTab: return "plus"
            case .closeTab: return "xmark"
            default: return "safari"
            }
        case .systemControl(let action):
            return action.defaultSystemImageName
        case .obsControl(let action):
            return action.defaultSystemImageName
        case .discordControl(let action):
            return action.defaultSystemImageName
        }
    }
}

extension Notification.Name {
    static let openTileLibraryForSlot = Notification.Name("openTileLibraryForSlot")
}
