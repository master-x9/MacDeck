//
//  LibraryTabs.swift
//  MacDeck (macOS Host)
//
//  Tile library picker with five tabs: Apps, Controls (⌃), Shortcuts, Websites, Setup.
//  Each tab provides a grid of draggable items with authentic Mac keycap styling,
//  live search, click-to-assign, rich website favicons, custom website management,
//  and full drag-and-drop support.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - Favicon Loader & Cache

enum WebsiteIconLoader {
    private static var cache = [String: Data]()
    private static let lock = NSLock()

    static func cachedIconData(for urlString: String) -> Data? {
        guard let domainName = domain(from: urlString) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cache[domainName]
    }

    static func iconData(for urlString: String) async -> Data? {
        guard let domainName = domain(from: urlString) else { return nil }

        lock.lock()
        if let cached = cache[domainName] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Fetch high-res favicon from Google S2 Favicon API
        guard let encodedDomain = domainName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(encodedDomain)&sz=128") else {
            return nil
        }

        do {
            var request = URLRequest(url: faviconURL)
            request.timeoutInterval = 2.5
            let (data, _) = try await URLSession.shared.data(for: request)
            if let image = NSImage(data: data), image.size.width > 0 {
                let finalData = compositeFavicon(image: image) ?? image.pngData(size: CGSize(width: 128, height: 128))
                if let finalData {
                    lock.lock()
                    cache[domainName] = finalData
                    lock.unlock()
                }
                return finalData
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func compositeFavicon(image: NSImage, size: CGSize = CGSize(width: 128, height: 128)) -> Data? {
        let canvas = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: size.width * 0.22, yRadius: size.height * 0.22)
            NSColor(calibratedWhite: 0.14, alpha: 1.0).setFill()
            path.fill()

            let inset: CGFloat = size.width * 0.16
            let drawRect = rect.insetBy(dx: inset, dy: inset)
            image.draw(in: drawRect)
            return true
        }
        return canvas.pngData(size: size)
    }

    static func domain(from urlString: String) -> String? {
        var normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.lowercased().hasPrefix("http://") && !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }
        return URL(string: normalized)?.host
    }
}

// MARK: - Custom Websites Store

struct CustomWebsiteItem: Identifiable, Codable, Hashable {
    var id: String { url }
    var name: String
    var url: String
}

@MainActor
final class CustomWebsitesStore: ObservableObject {
    static let shared = CustomWebsitesStore()

    @Published var customSites: [CustomWebsiteItem] = []

    private let storageKey = "macdeck.customWebsites"

    private init() {
        load()
    }

    func add(name: String, url: String) {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if !normalized.lowercased().hasPrefix("http://") && !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }

        var finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalName.isEmpty {
            let host = URL(string: normalized)?.host ?? normalized
            finalName = host.replacingOccurrences(of: "www.", with: "")
            if let dotIndex = finalName.firstIndex(of: ".") {
                finalName = String(finalName[..<dotIndex]).capitalized
            } else {
                finalName = finalName.capitalized
            }
        }

        customSites.removeAll { $0.url.lowercased() == normalized.lowercased() }
        customSites.insert(CustomWebsiteItem(name: finalName, url: normalized), at: 0)
        save()

        // Pre-fetch favicon in background
        Task {
            _ = await WebsiteIconLoader.iconData(for: normalized)
        }
    }

    func remove(url: String) {
        customSites.removeAll { $0.url.lowercased() == url.lowercased() }
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([CustomWebsiteItem].self, from: data) {
            self.customSites = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(customSites) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Apps Cache

@MainActor
final class AppsCache: ObservableObject {
    static let shared = AppsCache()

    @Published var apps: [(bundleID: String, name: String, icon: NSImage)] = []
    @Published var isLoading = false
    var loadError: String? = nil

    private init() {}

    func loadIfNeeded() {
        guard apps.isEmpty, !isLoading else { return }
        isLoading = true
        loadError = nil

        let engine = SystemActionEngine.shared
        Task.detached(priority: .userInitiated) {
            let discovered = engine.discoverInstalledApps()
            await MainActor.run {
                self.apps = discovered
                self.isLoading = false
            }
        }
    }

    func filtered(searchText: String) -> [(bundleID: String, name: String, icon: NSImage)] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - Shortcuts Cache

@MainActor
final class ShortcutsCache: ObservableObject {
    static let shared = ShortcutsCache()

    @Published var shortcuts: [String] = []
    @Published var isLoading = false
    var loadError: String? = nil

    private init() {}

    func loadIfNeeded() {
        guard shortcuts.isEmpty, !isLoading else { return }
        DispatchQueue.main.async { self.isLoading = true }
        loadError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let names = output
                    .split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                DispatchQueue.main.async {
                    self.shortcuts = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load shortcuts: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    func filtered(searchText: String) -> [String] {
        guard !searchText.isEmpty else { return shortcuts }
        return shortcuts.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - Main Tile Library View

struct TileLibraryView: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    @Binding var selectedSlot: Int?
    @Binding var showingLibrary: Bool

    @State private var selectedTab: Int = 1 // Defaults to Controls tab
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar with Tab Buttons & Search
            HStack(spacing: 12) {
                // Tab Selection Pills
                HStack(spacing: 4) {
                    LibraryTabButton(
                        title: "Controls",
                        customIcon: "control",
                        useSfSymbol: true,
                        tag: 1,
                        selectedTab: $selectedTab,
                        searchText: $searchText
                    )
                    LibraryTabButton(
                        title: "Apps",
                        customIcon: "square.grid.2x2",
                        useSfSymbol: true,
                        tag: 0,
                        selectedTab: $selectedTab,
                        searchText: $searchText
                    )
                    LibraryTabButton(
                        title: "Shortcuts",
                        customIcon: "bolt.fill",
                        useSfSymbol: true,
                        tag: 2,
                        selectedTab: $selectedTab,
                        searchText: $searchText
                    )
                    LibraryTabButton(
                        title: "Websites",
                        customIcon: "globe",
                        useSfSymbol: true,
                        tag: 3,
                        selectedTab: $selectedTab,
                        searchText: $searchText
                    )
                    LibraryTabButton(
                        title: "Setup",
                        customIcon: "slider.horizontal.2",
                        useSfSymbol: true,
                        tag: 4,
                        selectedTab: $selectedTab,
                        searchText: $searchText
                    )
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                )

                Spacer()

                // Integrated Search Field (for Apps, Shortcuts, Websites)
                if selectedTab == 0 || selectedTab == 2 || selectedTab == 3 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField(selectedTab == 3 ? "Filter websites…" : "Filter items…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .focused($isSearchFocused)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(width: 180)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSearchFocused ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 0.8)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .opacity(0.5)

            // Tab Content
            Group {
                switch selectedTab {
                case 1:
                    ControlsLibraryGrid(selectedSlot: $selectedSlot, showingLibrary: $showingLibrary)
                case 0:
                    AppsLibraryGrid(selectedSlot: $selectedSlot, showingLibrary: $showingLibrary, searchText: searchText)
                case 2:
                    ShortcutsLibraryGrid(selectedSlot: $selectedSlot, showingLibrary: $showingLibrary, searchText: searchText)
                case 3:
                    WebsitesLibraryGrid(selectedSlot: $selectedSlot, showingLibrary: $showingLibrary, searchText: searchText)
                case 4:
                    SetupLibraryGrid(selectedSlot: $selectedSlot, showingLibrary: $showingLibrary)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .proCard(cornerRadius: 16)
    }
}

// MARK: - Tab Button

struct LibraryTabButton: View {
    let title: String
    let customIcon: String
    let useSfSymbol: Bool
    let tag: Int

    @Binding var selectedTab: Int
    @Binding var searchText: String

    @State private var isHovered = false

    var isSelected: Bool { selectedTab == tag }

    var body: some View {
        Button {
            searchText = ""
            withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                selectedTab = tag
            }
        } label: {
            HStack(spacing: 5) {
                if tag == 1 {
                    // Authentic Mac keyboard Control key symbol
                    Text("⌃")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.6))
                } else {
                    Image(systemName: customIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.6))
                }

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected ?
                        Color.white.opacity(0.18) :
                        (isHovered ? Color.white.opacity(0.08) : Color.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Controls Tab (Authentic Mac Keyboard Control Keycaps)

struct ControlsLibraryGrid: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    @Binding var selectedSlot: Int?
    @Binding var showingLibrary: Bool

    private let controls = SystemControlAction.allCases

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 10)], spacing: 10) {
                ForEach(controls, id: \.self) { control in
                    ControlKeycapChip(
                        control: control,
                        slotIndex: selectedSlot,
                        onSelect: {
                            if let slot = selectedSlot {
                                let tile = DeckTile(slotIndex: slot, tileType: .systemControl(action: control))
                                store.assignTile(tile, toSlot: slot) {
                                    network.broadcastPageUpdate()
                                }
                                showingLibrary = false
                                selectedSlot = nil
                            }
                        }
                    )
                    .onDrag {
                        let payload = DragTilePayload(
                            kind: .control,
                            bundleID: nil,
                            appName: nil,
                            control: control,
                            url: nil,
                            websiteName: nil,
                            shortcutName: nil
                        )
                        if let data = try? JSONEncoder().encode(payload) {
                            return NSItemProvider(item: data as NSData, typeIdentifier: UTType.data.identifier)
                        }
                        return NSItemProvider()
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct ControlKeycapChip: View {
    let control: SystemControlAction
    let slotIndex: Int?
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                Spacer(minLength: 16)

                // Laser-etched Mac control symbol
                Image(systemName: control.defaultSystemImageName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .frame(height: 28)
                    .shadow(color: Color.white.opacity(0.2), radius: 2)

                // Label
                Text(control.displayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .keycapSurface(isHovered: isHovered, isControl: true, cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Drag onto a slot or click to assign")
    }
}

// MARK: - Apps Tab

struct AppsLibraryGrid: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    @Binding var selectedSlot: Int?
    @Binding var showingLibrary: Bool
    let searchText: String

    @StateObject private var cache = AppsCache.shared

    var body: some View {
        VStack(spacing: 0) {
            if cache.isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning /Applications…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = cache.loadError {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                let apps = cache.filtered(searchText: searchText)
                if apps.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No apps found" : "No matches",
                        systemImage: searchText.isEmpty ? "square.grid.2x2" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "No installed apps found." : "Try a different search query.")
                    )
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 10)], spacing: 10) {
                            ForEach(apps, id: \.bundleID) { app in
                                AppKeycapChip(
                                    bundleID: app.bundleID,
                                    name: app.name,
                                    icon: app.icon,
                                    slotIndex: selectedSlot,
                                    onSelect: {
                                        if let slot = selectedSlot {
                                            store.assignAppTile(bundleID: app.bundleID, name: app.name, icon: app.icon, toSlot: slot) {
                                                network.broadcastPageUpdate()
                                            }
                                            showingLibrary = false
                                            selectedSlot = nil
                                        }
                                    }
                                )
                                .onDrag {
                                    let payload = DragTilePayload(
                                        kind: .app,
                                        bundleID: app.bundleID,
                                        appName: app.name,
                                        control: nil,
                                        url: nil,
                                        websiteName: nil,
                                        shortcutName: nil
                                    )
                                    if let data = try? JSONEncoder().encode(payload) {
                                        return NSItemProvider(item: data as NSData, typeIdentifier: UTType.data.identifier)
                                    }
                                    return NSItemProvider()
                                }
                            }
                        }
                        .padding(14)
                    }
                }
            }
        }
        .onAppear {
            cache.loadIfNeeded()
        }
    }
}

private struct AppKeycapChip: View {
    let bundleID: String
    let name: String
    let icon: NSImage
    let slotIndex: Int?
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .cornerRadius(8)
                    .shadow(color: Color.black.opacity(0.3), radius: 2, y: 1)

                Text(name)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .keycapSurface(isHovered: isHovered, cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Drag onto a slot or click to assign")
    }
}

// MARK: - Shortcuts Tab

struct ShortcutsLibraryGrid: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    @Binding var selectedSlot: Int?
    @Binding var showingLibrary: Bool
    let searchText: String

    @StateObject private var cache = ShortcutsCache.shared

    var body: some View {
        VStack(spacing: 0) {
            if cache.isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading macOS Shortcuts…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = cache.loadError {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                let shortcuts = cache.filtered(searchText: searchText)
                if shortcuts.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No shortcuts" : "No matches",
                        systemImage: searchText.isEmpty ? "bolt.fill" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "No Shortcuts created in the Shortcuts app." : "Try a different search.")
                    )
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 10)], spacing: 10) {
                            ForEach(shortcuts, id: \.self) { name in
                                ShortcutKeycapChip(
                                    name: name,
                                    slotIndex: selectedSlot,
                                    onSelect: {
                                        if let slot = selectedSlot {
                                            let tile = DeckTile(slotIndex: slot, tileType: .shortcut(name: name))
                                            store.assignTile(tile, toSlot: slot) {
                                                network.broadcastPageUpdate()
                                            }
                                            showingLibrary = false
                                            selectedSlot = nil
                                        }
                                    }
                                )
                                .onDrag {
                                    let payload = DragTilePayload(
                                        kind: .shortcut,
                                        bundleID: nil,
                                        appName: nil,
                                        control: nil,
                                        url: nil,
                                        websiteName: nil,
                                        shortcutName: name
                                    )
                                    if let data = try? JSONEncoder().encode(payload) {
                                        return NSItemProvider(item: data as NSData, typeIdentifier: UTType.data.identifier)
                                    }
                                    return NSItemProvider()
                                }
                            }
                        }
                        .padding(14)
                    }
                }
            }
        }
        .onAppear {
            cache.loadIfNeeded()
        }
    }
}

private struct ShortcutKeycapChip: View {
    let name: String
    let slotIndex: Int?
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.pink.opacity(0.3), Color.purple.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)

                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.pink.opacity(0.9))
                }

                Text(name)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .keycapSurface(isHovered: isHovered, cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Drag onto a slot or click to assign")
    }
}

// MARK: - Websites Tab

struct WebsitesLibraryGrid: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager
    @StateObject private var customWebsitesStore = CustomWebsitesStore.shared

    @Binding var selectedSlot: Int?
    @Binding var showingLibrary: Bool
    var searchText: String = ""

    @State private var customURL: String = ""
    @State private var customName: String = ""
    @State private var isAddingExpanded: Bool = false

    private let defaultPopularSites: [(name: String, url: String)] = [
        ("YouTube", "https://youtube.com"),
        ("ChatGPT", "https://chatgpt.com"),
        ("GitHub", "https://github.com"),
        ("Google", "https://google.com"),
        ("Spotify", "https://spotify.com"),
        ("Netflix", "https://netflix.com"),
        ("Twitter / X", "https://x.com"),
        ("Instagram", "https://instagram.com"),
        ("Notion", "https://notion.so"),
        ("Figma", "https://figma.com"),
        ("Gmail", "https://mail.google.com"),
        ("Reddit", "https://reddit.com"),
        ("Twitch", "https://twitch.tv"),
        ("Discord", "https://discord.com"),
        ("WhatsApp", "https://web.whatsapp.com"),
        ("Apple", "https://apple.com"),
    ]

    private var filteredPopularSites: [(name: String, url: String)] {
        if searchText.isEmpty { return defaultPopularSites }
        return defaultPopularSites.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredCustomSites: [CustomWebsiteItem] {
        if searchText.isEmpty { return customWebsitesStore.customSites }
        return customWebsitesStore.customSites.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                // Custom Website Add Bar
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)

                    TextField("Website URL (e.g. twitch.tv, cnbc.com)…", text: $customURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { addCustomWebsite() }

                    TextField("Name (optional)", text: $customName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 110)
                        .onSubmit { addCustomWebsite() }

                    Button {
                        addCustomWebsite()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text("Add Site")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.8)
                )
                .padding(.horizontal, 14)
                .padding(.top, 10)

                // 1. Custom Websites Section (if any exist)
                if !filteredCustomSites.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("MY CUSTOM SITES")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .tracking(0.6)

                            Text("(\(filteredCustomSites.count))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary.opacity(0.8))
                        }
                        .padding(.horizontal, 14)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 10)], spacing: 10) {
                            ForEach(filteredCustomSites) { site in
                                WebsiteKeycapChip(
                                    name: site.name,
                                    url: site.url,
                                    slotIndex: selectedSlot,
                                    isCustom: true,
                                    onDelete: {
                                        withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                                            customWebsitesStore.remove(url: site.url)
                                        }
                                    },
                                    onSelect: {
                                        assignWebsiteToSlot(name: site.name, url: site.url)
                                    }
                                )
                                .onDrag {
                                    createDragProvider(name: site.name, url: site.url)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }

                // 2. Popular Websites Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("POPULAR SITES")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                        .padding(.horizontal, 14)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 10)], spacing: 10) {
                        ForEach(filteredPopularSites, id: \.name) { site in
                            WebsiteKeycapChip(
                                name: site.name,
                                url: site.url,
                                slotIndex: selectedSlot,
                                isCustom: false,
                                onDelete: nil,
                                onSelect: {
                                    assignWebsiteToSlot(name: site.name, url: site.url)
                                }
                            )
                            .onDrag {
                                createDragProvider(name: site.name, url: site.url)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private func addCustomWebsite() {
        let trimmedURL = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        let trimmedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)

        withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
            customWebsitesStore.add(name: trimmedName, url: trimmedURL)
        }

        // If a slot is currently selected, assign it directly
        if let slot = selectedSlot {
            var normalized = trimmedURL
            if !normalized.lowercased().hasPrefix("http://") && !normalized.lowercased().hasPrefix("https://") {
                normalized = "https://\(normalized)"
            }
            let host = URL(string: normalized)?.host ?? normalized
            let siteName = trimmedName.isEmpty ? host : trimmedName
            assignWebsiteToSlot(name: siteName, url: normalized)
        }

        customURL = ""
        customName = ""
    }

    private func assignWebsiteToSlot(name: String, url: String) {
        if let slot = selectedSlot {
            let cached = WebsiteIconLoader.cachedIconData(for: url)
            let tile = DeckTile(
                slotIndex: slot,
                tileType: .website(url: url, name: name),
                iconData: cached
            )
            store.assignTile(tile, toSlot: slot) {
                network.broadcastPageUpdate()
            }
            showingLibrary = false
            selectedSlot = nil
        }
    }

    private func createDragProvider(name: String, url: String) -> NSItemProvider {
        let payload = DragTilePayload(
            kind: .website,
            bundleID: nil,
            appName: nil,
            control: nil,
            url: url,
            websiteName: name,
            shortcutName: nil
        )
        if let data = try? JSONEncoder().encode(payload) {
            return NSItemProvider(item: data as NSData, typeIdentifier: UTType.data.identifier)
        }
        return NSItemProvider()
    }
}

private struct WebsiteKeycapChip: View {
    let name: String
    let url: String
    let slotIndex: Int?
    var isCustom: Bool = false
    var onDelete: (() -> Void)? = nil
    let onSelect: () -> Void

    @State private var iconData: Data? = nil
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    // Favicon Image / Crisp Logo View
                    ZStack {
                        if let iconData, let nsImage = NSImage(data: iconData) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 36, height: 36)
                                .cornerRadius(8)
                                .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                        } else {
                            // Sleek placeholder while fetching
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.blue.opacity(0.18))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Image(systemName: "globe")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(Color.blue.opacity(0.9))
                                )
                        }
                    }

                    Text(name)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.white.opacity(0.9))
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .keycapSurface(isHovered: isHovered, cornerRadius: 12)

                // Delete custom site badge on hover
                if isCustom && isHovered, let onDelete {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white, Color.red)
                            .shadow(color: Color.black.opacity(0.5), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onAppear {
            if iconData == nil {
                if let cached = WebsiteIconLoader.cachedIconData(for: url) {
                    self.iconData = cached
                }
            }
        }
        .task {
            if iconData == nil {
                if let data = await WebsiteIconLoader.iconData(for: url) {
                    self.iconData = data
                }
            }
        }
        .contextMenu {
            if isCustom, let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Custom Site", systemImage: "trash")
                }
            }
        }
        .help("Drag onto a slot or click to assign")
    }
}

// MARK: - Setup & Macro Recorder Tab

struct SetupLibraryGrid: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    @Binding var selectedSlot: Int?
    @Binding var showingLibrary: Bool

    @State private var hasAX = SystemActionEngine.shared.hasAccessibilityPermission

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                // Macro Recorder Component
                MacroRecorderView(
                    selectedSlot: $selectedSlot,
                    showingLibrary: $showingLibrary
                )

                // Accessibility & Connection Helpers
                HStack(spacing: 10) {
                    SetupStatusCard(
                        title: hasAX ? "Accessibility Active" : "Grant Accessibility",
                        subtitle: hasAX ? "Media keys & system controls ready" : "Required for keyboard and system control",
                        icon: hasAX ? "checkmark.seal.fill" : "lock.shield.fill",
                        tint: hasAX ? .green : .orange,
                        actionTitle: hasAX ? nil : "Enable",
                        onAction: {
                            if !hasAX {
                                let granted = SystemActionEngine.shared.refreshAccessibilityPermission(prompt: true)
                                if granted { hasAX = true }
                            }
                        }
                    )

                    SetupStatusCard(
                        title: "Bonjour Service",
                        subtitle: "Ready for connections",
                        icon: "antenna.radiowaves.left.and.right",
                        tint: .blue,
                        actionTitle: nil,
                        onAction: nil
                    )
                }
            }
            .padding(14)
        }
        .onAppear {
            hasAX = SystemActionEngine.shared.refreshAccessibilityPermission(prompt: false)
        }
    }
}

private struct SetupStatusCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let actionTitle: String?
    let onAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .keycapSurface(isControl: true, cornerRadius: 12)
    }
}

// MARK: - Macro Recorder

struct MacroRecorderView: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    @Binding var selectedSlot: Int?
    @Binding var showingLibrary: Bool

    @State private var recordedKeyCode: UInt16? = nil
    @State private var keyString: String = ""
    @State private var isRecording: Bool = false

    @State private var hasCommand: Bool = false
    @State private var hasOption: Bool = false
    @State private var hasControl: Bool = false
    @State private var hasShift: Bool = false

    private var computedFlags: CGEventFlags {
        var flags = CGEventFlags()
        if hasCommand { flags.insert(.maskCommand) }
        if hasOption { flags.insert(.maskAlternate) }
        if hasControl { flags.insert(.maskControl) }
        if hasShift { flags.insert(.maskShift) }
        return flags
    }

    private var fullDisplayString: String {
        guard recordedKeyCode != nil else { return "" }
        var str = ""
        if hasControl { str += "⌃" }
        if hasOption { str += "⌥" }
        if hasShift { str += "⇧" }
        if hasCommand { str += "⌘" }
        str += keyString
        return str
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Custom Key Combo / Macro")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Drag or assign to any slot")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Modifier Key Toggles
            HStack(spacing: 6) {
                Toggle("⌘ Cmd", isOn: $hasCommand).toggleStyle(.button)
                Toggle("⌥ Opt", isOn: $hasOption).toggleStyle(.button)
                Toggle("⌃ Ctrl", isOn: $hasControl).toggleStyle(.button)
                Toggle("⇧ Shift", isOn: $hasShift).toggleStyle(.button)
            }
            .controlSize(.small)

            // Input Recording Field & Add Button
            HStack(spacing: 8) {
                ZStack(alignment: .trailing) {
                    NativeMacroRecorderField(
                        recordedKeyCode: $recordedKeyCode,
                        keyString: $keyString,
                        isRecording: $isRecording,
                        fullDisplayString: fullDisplayString
                    )
                    .frame(height: 32)

                    if !keyString.isEmpty && !isRecording {
                        Button {
                            clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                    }
                }

                Button("Assign to Slot") {
                    addMacro()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(recordedKeyCode == nil || isRecording || selectedSlot == nil)
            }
        }
        .padding(12)
        .keycapSurface(isControl: true, cornerRadius: 12)
    }

    private func clear() {
        recordedKeyCode = nil
        keyString = ""
        isRecording = false
        hasCommand = false
        hasOption = false
        hasControl = false
        hasShift = false
    }

    private func addMacro() {
        guard let slot = selectedSlot, let code = recordedKeyCode else { return }

        let macroString = "MACRO|\(code)|\(computedFlags.rawValue)"
        var tile = DeckTile(slotIndex: slot, tileType: .shortcut(name: macroString))
        tile.customLabel = fullDisplayString
        tile.iconData = createTextIcon(text: fullDisplayString)

        store.assignTile(tile, toSlot: slot) {
            network.broadcastPageUpdate()
        }
        showingLibrary = false
        selectedSlot = nil
    }

    private func createTextIcon(text: String) -> Data? {
        let size = CGSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()

        if let context = NSGraphicsContext.current?.cgContext {
            context.setFillColor(NSColor(white: 0.15, alpha: 1.0).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }

        let fontSize: CGFloat = text.count > 2 ? 28 : 42
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]

        let stringSize = text.size(withAttributes: attributes)
        let point = CGPoint(
            x: (size.width - stringSize.width) / 2,
            y: (size.height - stringSize.height) / 2
        )

        text.draw(at: point, withAttributes: attributes)
        image.unlockFocus()
        return image.pngData(size: size)
    }
}

struct NativeMacroRecorderField: NSViewRepresentable {
    @Binding var recordedKeyCode: UInt16?
    @Binding var keyString: String
    @Binding var isRecording: Bool
    let fullDisplayString: String

    class Coordinator: NSObject {
        var parent: NativeMacroRecorderField

        init(_ parent: NativeMacroRecorderField) {
            self.parent = parent
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> MacroRecorderNSView {
        let view = MacroRecorderNSView()
        view.onRecord = { code, str in
            context.coordinator.parent.recordedKeyCode = code
            context.coordinator.parent.keyString = str
            context.coordinator.parent.isRecording = false
        }
        view.onStateChange = { recording in
            context.coordinator.parent.isRecording = recording
        }
        return view
    }

    func updateNSView(_ nsView: MacroRecorderNSView, context: Context) {
        context.coordinator.parent = self
        nsView.displayString = fullDisplayString
        nsView.isRecording = isRecording
        nsView.needsDisplay = true
    }
}

class MacroRecorderNSView: NSView {
    var displayString: String = ""
    var isRecording: Bool = false

    var onRecord: ((UInt16, String) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    private var helper: MacroRecorderHelper?

    override var acceptsFirstResponder: Bool { true }
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if let window = self.window {
            window.makeFirstResponder(self)
        }
        isRecording = true
        onStateChange?(true)
        needsDisplay = true

        if helper == nil {
            helper = MacroRecorderHelper()
            helper?.onEvent = { [weak self] cgEvent in
                guard let self = self, self.isRecording else { return }
                if let nsEvent = NSEvent(cgEvent: cgEvent) {
                    self.handleKeyEvent(nsEvent)
                }
            }
        }
        helper?.start()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        onStateChange?(false)
        needsDisplay = true
        helper?.stop()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = event.keyCode
        var str = ""
        var chars = ""
        if let nsChars = event.charactersIgnoringModifiers?.uppercased() {
            chars = nsChars
        }

        if !chars.isEmpty {
            switch keyCode {
            case 36: str = "RETURN"
            case 48: str = "TAB"
            case 49: str = "SPACE"
            case 51: str = "DELETE"
            case 53: str = "ESC"
            case 123: str = "←"
            case 124: str = "→"
            case 125: str = "↓"
            case 126: str = "↑"
            default: str = chars
            }
        } else {
            str = "Key \(keyCode)"
        }

        onRecord?(keyCode, str)
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds
        guard bounds.width > 2, bounds.height > 2 else { return }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)

        if isRecording {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }

        NSColor.controlBackgroundColor.setFill()
        path.fill()
        path.stroke()

        let textToDraw: String
        let textColor: NSColor

        if isRecording {
            textToDraw = "Listening for key press…"
            textColor = .secondaryLabelColor
        } else if !displayString.isEmpty {
            textToDraw = displayString
            textColor = .labelColor
        } else {
            textToDraw = "Click to record shortcut key"
            textColor = .secondaryLabelColor
        }

        let font = isRecording || displayString.isEmpty ? NSFont.systemFont(ofSize: 12) : NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        let stringSize = textToDraw.size(withAttributes: attrs)
        let width = max(0, bounds.width - 20)
        let height = max(0, stringSize.height)
        let rect = NSRect(
            x: 10,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
        textToDraw.draw(in: rect, withAttributes: attrs)
    }
}
