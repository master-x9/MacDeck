//
//  PageStore.swift
//  MacDeck (macOS Host)
//
//  Observable page state that owns the array of DeckPage objects,
//  tracks the currently-selected (active) page, and persists to disk.
//  All mutation methods accept a broadcastUpdate closure so the view
//  layer can trigger network.broadcastPageUpdate() after any edit.
//

import AppKit
import Combine
import SQLite3
import SwiftUI

@MainActor
final class PageStore: ObservableObject {

    // MARK: - Published state

    let runningAppsMonitor = RunningAppsMonitor()
    let browserMonitor = BrowserMonitor()
    private var cancellables = Set<AnyCancellable>()

    @Published var pages: [DeckPage] {
        didSet { save() }
    }
    @Published var selectedPageID: UUID?
    
    @Published var showRunningAppsPage: Bool = true {
        didSet {
            UserDefaults.standard.set(showRunningAppsPage, forKey: "phonedeck.showRunningAppsPage")
            runningAppsMonitor.isEnabled = showRunningAppsPage
            if !showRunningAppsPage && isRunningAppsSelected {
                selectedPageID = pages.first?.id
            }
        }
    }
    
    @Published var showBrowserControlPage: Bool = true {
        didSet {
            UserDefaults.standard.set(showBrowserControlPage, forKey: "phonedeck.showBrowserControlPage")
            if !showBrowserControlPage && isBrowserControlSelected {
                selectedPageID = pages.first?.id
            }
        }
    }

    /// The page currently shown in the phone-frame preview (and sent to the phone).
    var activePage: DeckPage? {
        if showBrowserControlPage, let bp = browserMonitor.browserPage, selectedPageID == BrowserMonitor.browserPageID {
            return bp
        }
        if showRunningAppsPage && selectedPageID == RunningAppsMonitor.runningAppsPageID {
            return runningAppsMonitor.runningAppsPage
        }
        return pages.first { $0.id == selectedPageID }
    }

    /// All pages including dynamic pages at the top.
    var allPages: [DeckPage] {
        var list: [DeckPage] = []
        if showBrowserControlPage, let bp = browserMonitor.browserPage {
            list.append(bp)
        }
        if showRunningAppsPage {
            list.append(runningAppsMonitor.runningAppsPage)
        }
        list.append(contentsOf: pages)
        return list
    }

    /// Whether the Running Apps page is currently selected.
    var isRunningAppsSelected: Bool {
        selectedPageID == RunningAppsMonitor.runningAppsPageID
    }
    
    /// Whether the Browser Control page is currently selected.
    var isBrowserControlSelected: Bool {
        selectedPageID == BrowserMonitor.browserPageID
    }

    /// Index of the active page in the array, if any.
    var activePageIndex: Int? {
        pages.firstIndex { $0.id == selectedPageID }
    }

    // MARK: - Persistence

    private static let storageKey = "phonedeck.pages"

    private static var storageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PhoneDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pages.json")
    }

    // MARK: - Init

    init() {
        UserDefaults.standard.register(defaults: [
            "phonedeck.showRunningAppsPage": true,
            "phonedeck.showBrowserControlPage": true
        ])
        self.showRunningAppsPage = UserDefaults.standard.bool(forKey: "phonedeck.showRunningAppsPage")
        self.showBrowserControlPage = UserDefaults.standard.bool(forKey: "phonedeck.showBrowserControlPage")
        
        if let data = try? Data(contentsOf: Self.storageURL),
           let decoded = try? JSONDecoder().decode([DeckPage].self, from: data),
           !decoded.isEmpty {
            let normalized = Self.normalizedPages(decoded)
            self.pages = normalized
            self.selectedPageID = normalized.first?.id
            Task {
                await populateMissingWebsiteIcons()
            }
        } else {
            // Start with one empty default page.
            let defaultPage = DeckPage(name: "Main", pageNumber: 1)
            self.pages = [defaultPage]
            self.selectedPageID = defaultPage.id
        }

        // Re-publish when dynamic pages change so the UI updates.
        runningAppsMonitor.$runningAppsPage
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        browserMonitor.$browserPage
            .sink { [weak self] newPage in
                guard let self else { return }
                if newPage == nil && self.selectedPageID == BrowserMonitor.browserPageID {
                    self.selectedPageID = self.pages.first?.id
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private static func normalizedPages(_ pages: [DeckPage]) -> [DeckPage] {
        pages.map { page in
            var normalizedPage = page
            if normalizedPage.tiles.count < DeckPage.slotCount {
                normalizedPage.tiles.append(
                    contentsOf: Array(repeating: nil, count: DeckPage.slotCount - normalizedPage.tiles.count)
                )
            } else if normalizedPage.tiles.count > DeckPage.slotCount {
                normalizedPage.tiles = Array(normalizedPage.tiles.prefix(DeckPage.slotCount))
            }
            normalizedPage.tiles = normalizedPage.tiles.map { tile -> DeckTile? in
                guard var tile else { return nil }

                // If icon already present (custom user icon, saved image, etc.), PRESERVE IT COMPLETELY!
                if tile.iconData != nil {
                    return tile
                }

                switch tile.tileType {
                case .app(let bundleID, _):
                    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                        tile.iconData = icon.pngData(size: CGSize(width: 144, height: 144))
                    } else {
                        tile.iconData = SFSymbolIconGenerator.generate(
                            symbolName: "app.dashed",
                            foreground: NSColor.white,
                            background: NSColor.systemGray
                        )
                    }
                case .systemControl(let action):
                    tile.iconData = SFSymbolIconGenerator.generate(
                        symbolName: action.defaultSystemImageName,
                        foreground: NSColor.white,
                        background: NSColor.clear
                    )
                case .website:
                    // Provide a fallback only if iconData is completely missing.
                    tile.iconData = SFSymbolIconGenerator.generate(
                        symbolName: "globe",
                        foreground: NSColor.white,
                        background: NSColor.systemBlue
                    )
                case .shortcut:
                    tile.iconData = SFSymbolIconGenerator.generate(
                        symbolName: "bolt.fill",
                        foreground: NSColor.white,
                        background: NSColor.systemPurple
                    )
                case .browserControl:
                    tile.iconData = SFSymbolIconGenerator.generate(
                        symbolName: "safari",
                        foreground: NSColor.white,
                        background: NSColor.clear
                    )
                }

                return tile
            }
            return normalizedPage
        }
    }

    private func populateMissingWebsiteIcons() async {
        var updatedPages = pages
        var didUpdate = false

        for pageIndex in updatedPages.indices {
            for tileIndex in updatedPages[pageIndex].tiles.indices {
                guard var tile = updatedPages[pageIndex].tiles[tileIndex],
                      case .website(let url, _) = tile.tileType else {
                    continue
                }

                // If the user already set a custom icon or an icon exists, NEVER overwrite it on relaunch!
                if tile.iconData != nil {
                    continue
                }

                guard let iconData = await WebsiteIconLoader.iconData(for: url) else {
                    continue
                }

                tile.iconData = iconData
                updatedPages[pageIndex].tiles[tileIndex] = tile
                didUpdate = true
            }
        }

        if didUpdate {
            pages = updatedPages
            save()
            objectWillChange.send()
        }
    }

    private func save() {
        Task.detached(priority: .utility) { [pages = self.pages] in
            do {
                let data = try JSONEncoder().encode(pages)
                try data.write(to: Self.storageURL, options: .atomic)
            } catch {
                NSLog("PhoneDeck: failed to persist pages: \(error)")
            }
        }
    }

    // MARK: - Page CRUD

    func addPage() {
        let number = (pages.map(\.pageNumber).max() ?? 0) + 1
        let page = DeckPage(name: "Page \(number)", pageNumber: number)
        pages.append(page)
        selectedPageID = page.id
    }

    func deletePage(_ pageID: UUID) {
        guard pages.count > 1 else { return } // keep at least one page
        pages.removeAll { $0.id == pageID }
        if selectedPageID == pageID {
            selectedPageID = pages.first?.id
        }
    }

    func renamePage(_ pageID: UUID, to name: String, broadcastUpdate: (() -> Void)? = nil) {
        guard let idx = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[idx].name = name
        broadcastUpdate?()
    }

    // MARK: - Tile mutations

    /// Assigns a tile to a slot on the active page. If the tile comes from the
    /// Apps library, callers should pre-populate `tile.iconData` via
    /// `NSImage.pngData(size:)` before calling this method.
    func assignTile(_ tile: DeckTile, toSlot slot: Int, broadcastUpdate: (() -> Void)? = nil) {
        guard let idx = activePageIndex, slot >= 0, slot < DeckPage.slotCount else { return }
        var updatedTile = tile
        updatedTile.slotIndex = slot

        // Ensure System Controls and Shortcuts get an icon rendered for the client.
        if updatedTile.iconData == nil {
            switch updatedTile.tileType {
            case .systemControl(let action):
                updatedTile.iconData = SFSymbolIconGenerator.generate(
                    symbolName: action.defaultSystemImageName,
                    foreground: NSColor.white,
                    background: NSColor.clear
                )
            case .shortcut:
                updatedTile.iconData = SFSymbolIconGenerator.generate(
                    symbolName: "bolt.fill",
                    foreground: NSColor.white,
                    background: NSColor.systemPurple
                )
            case .website(let url, _):
                updatedTile.iconData = SFSymbolIconGenerator.generate(
                    symbolName: "globe",
                    foreground: NSColor.white,
                    background: NSColor.systemBlue
                )
                pages[idx].tiles[slot] = updatedTile
                broadcastUpdate?()
                
                Task { [weak self] in
                    guard let iconData = await WebsiteIconLoader.iconData(for: url) else { return }
                    await MainActor.run {
                        guard let self = self,
                              let activeIdx = self.activePageIndex,
                              activeIdx < self.pages.count,
                              slot < self.pages[activeIdx].tiles.count,
                              case .website(let currentUrl, _) = self.pages[activeIdx].tiles[slot]?.tileType,
                              currentUrl == url else { return }
                        
                        self.pages[activeIdx].tiles[slot]?.iconData = iconData
                        broadcastUpdate?()
                    }
                }
                return
            case .app:
                updatedTile.iconData = SFSymbolIconGenerator.generate(
                    symbolName: "app.dashed",
                    foreground: NSColor.white,
                    background: NSColor.systemGray
                )
            case .browserControl:
                updatedTile.iconData = SFSymbolIconGenerator.generate(
                    symbolName: "safari",
                    foreground: NSColor.white,
                    background: NSColor.clear
                )
            }
        }

        pages[idx].tiles[slot] = updatedTile
        broadcastUpdate?()
    }

    /// Assigns a tile built from an app entry (with icon encoding baked in or reused).
    func assignAppTile(bundleID: String, name: String, icon: NSImage, iconData precomputedData: Data? = nil, toSlot slot: Int, broadcastUpdate: (() -> Void)? = nil) {
        let iconData = precomputedData ?? icon.pngData(size: CGSize(width: 144, height: 144))
        let tile = DeckTile(
            slotIndex: slot,
            tileType: .app(bundleIdentifier: bundleID, name: name),
            iconData: iconData
        )
        assignTile(tile, toSlot: slot, broadcastUpdate: broadcastUpdate)
    }

    func removeTile(atSlot slot: Int, broadcastUpdate: (() -> Void)? = nil) {
        guard let idx = activePageIndex, slot >= 0, slot < DeckPage.slotCount else { return }
        pages[idx].tiles[slot] = nil
        broadcastUpdate?()
    }

    /// Moves a tile from one slot to another on the active page.
    func moveTile(from sourceSlot: Int, to destinationSlot: Int, broadcastUpdate: (() -> Void)? = nil) {
        guard let idx = activePageIndex,
              sourceSlot >= 0, sourceSlot < DeckPage.slotCount,
              destinationSlot >= 0, destinationSlot < DeckPage.slotCount,
              sourceSlot != destinationSlot else { return }
        let sourceTile = pages[idx].tiles[sourceSlot]
        let destTile = pages[idx].tiles[destinationSlot]

        // Swap slots (if destination has a tile, move it to source)
        if var s = sourceTile {
            s.slotIndex = destinationSlot
            pages[idx].tiles[destinationSlot] = s
        } else {
            pages[idx].tiles[destinationSlot] = nil
        }
        if var d = destTile {
            d.slotIndex = sourceSlot
            pages[idx].tiles[sourceSlot] = d
        } else {
            pages[idx].tiles[sourceSlot] = nil
        }
        broadcastUpdate?()
    }

    /// Reorders pages in the sidebar (for drag-to-reorder).
    func movePage(from source: IndexSet, to destination: Int) {
        var updated = pages
        updated.move(fromOffsets: source, toOffset: destination)
        // Re-number pages to match their new positions
        for index in updated.indices {
            updated[index].pageNumber = index + 1
        }
        pages = updated
    }
}


enum SFSymbolIconGenerator {
    static func generate(symbolName: String, foreground: NSColor, background: NSColor, size: CGSize = CGSize(width: 144, height: 144)) -> Data? {
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: size.width * 0.18, yRadius: size.height * 0.18)
            background.setFill()
            path.fill()
            
            if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                .flatMap({ $0.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size.width * 0.52, weight: .semibold).applying(.init(hierarchicalColor: foreground))) }) {
                    let drawRect = NSRect(
                        x: (size.width - symbolImage.size.width) / 2,
                        y: (size.height - symbolImage.size.height) / 2,
                        width: symbolImage.size.width,
                        height: symbolImage.size.height
                    )
                    symbolImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        
        return image.pngData(size: size)
    }
}


@MainActor
final class BrowserMonitor: ObservableObject {
    static let browserPageID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    
    @Published private(set) var browserPage: DeckPage?
    
    // Internal state to prevent AppleScript polling from stacking up and causing massive delays
    private var isRefreshingTabs = false
    private var pendingRefresh = false
    
    private var timer: Timer?
    private var currentSessionID = UUID()
    private var lastTabsSignature: String = ""
    private let supportedBrowsers: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "com.operasoftware.Opera": "Opera",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.kagi.orion": "Orion",
        "org.mozilla.firefox": "Firefox"
    ]
    
    init() {
        checkActiveApp()
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(forceRefreshNotification),
            name: NSNotification.Name("triggerBrowserTabRefresh"),
            object: nil
        )
    }
    
    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc nonisolated private func appActivated(_ notification: Notification) {
        Task { @MainActor in
            self.checkActiveApp()
        }
    }
    
    @objc nonisolated private func forceRefreshNotification(_ notification: Notification) {
        Task { @MainActor in
            self.triggerImmediateRefresh()
        }
    }
    
    func triggerImmediateRefresh() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              let appName = getBrowserAppName(bundleID: bundleID, localizedName: app.localizedName) else { return }
        refreshTabs(for: bundleID, appName: appName, sessionID: currentSessionID)
    }
    
    private func checkActiveApp() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return }
        
        // Ignore focus changes to MacDeck, Xcode, or Terminal so clicking on MacDeck/Xcode to view logs doesn't clear the browser page!
        if bundleID == Bundle.main.bundleIdentifier ||
           bundleID == "com.apple.dt.Xcode" ||
           bundleID == "com.apple.Terminal" ||
           bundleID == "com.googlecode.iterm2" {
            return
        }
        
        if let appName = getBrowserAppName(bundleID: bundleID, localizedName: app.localizedName) {
            startPolling(for: bundleID, appName: appName)
        } else {
            stopPolling()
            browserPage = nil
        }
    }
    
    private func getBrowserAppName(bundleID: String, localizedName: String?) -> String? {
        if let knownName = supportedBrowsers[bundleID] {
            return knownName
        }
        let b = bundleID.lowercased()
        let n = (localizedName ?? "").lowercased()
        if b.contains("browser") || b.contains("chrome") || b.contains("safari") || b.contains("brave") || b.contains("edge") ||
           n.contains("browser") || n.contains("chrome") || n.contains("safari") || n.contains("brave") || n.contains("edge") {
            return localizedName ?? "Browser"
        }
        return nil
    }
    
    private func startPolling(for bundleID: String, appName: String) {
        timer?.invalidate()
        let sessionID = UUID()
        currentSessionID = sessionID
        
        // Immediately show page synchronously if needed
        if browserPage == nil {
            self.browserPage = Self.createFallbackPage(titles: ["Tab 1", "Tab 2", "Tab 3", "Tab 4", "Tab 5"])
        }
        
        refreshTabs(for: bundleID, appName: appName, sessionID: sessionID)
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refreshTabs(for: bundleID, appName: appName, sessionID: sessionID)
            }
        }
    }
    
    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        currentSessionID = UUID() // Invalidate any running tasks
        lastTabsSignature = ""
        isRefreshingTabs = false
        browserPage = nil
    }
    
    private func refreshTabs(for bundleID: String, appName: String, sessionID: UUID) {
        if isRefreshingTabs {
            pendingRefresh = true
            return
        }
        isRefreshingTabs = true
        pendingRefresh = false
        
        Task.detached {
            let script: String
            if bundleID == "com.apple.Safari" {
                script = """
                tell application "Safari"
                    if (count of windows) > 0 then
                        set tList to name of tabs of front window
                        set uList to URL of tabs of front window
                        set activeURL to URL of current tab of front window
                        if activeURL is missing value then set activeURL to ""
                        set res to {activeURL & "|||ACTIVE"}
                        repeat with i from 1 to count of tList
                            set end of res to (item i of tList) & "|||" & (item i of uList)
                        end repeat
                        return res
                    else
                        return {}
                    end if
                end tell
                """
            } else {
                script = """
                tell application "\(appName)"
                    if (count of windows) > 0 then
                        set tList to title of tabs of front window
                        set uList to URL of tabs of front window
                        set activeURL to URL of active tab of front window
                        if activeURL is missing value then set activeURL to ""
                        set res to {activeURL & "|||ACTIVE"}
                        repeat with i from 1 to count of tList
                            set end of res to (item i of tList) & "|||" & (item i of uList)
                        end repeat
                        return res
                    else
                        return {}
                    end if
                end tell
                """
            }
            
            var tabs: [(title: String, url: String)] = []
            var isNewTab = false
            
            if let appleScript = NSAppleScript(source: script) {
                var errorInfo: NSDictionary?
                let descriptor = appleScript.executeAndReturnError(&errorInfo)
                
                if descriptor.descriptorType == typeAEList {
                    let count = descriptor.numberOfItems
                    if count > 0 {
                        if let firstItemStr = descriptor.atIndex(1)?.stringValue {
                            let parts = firstItemStr.components(separatedBy: "|||")
                            let activeURL = parts.first ?? ""
                            isNewTab = activeURL.isEmpty || activeURL == "favorites://" || activeURL == "chrome://newtab/" || activeURL == "arc://newtab/" || activeURL.hasPrefix("vivaldi://newtab") || activeURL.hasPrefix("opera://startpage")
                        }
                        
                        if count > 1 {
                            for i in 2...min(6, count) {
                                if let itemStr = descriptor.atIndex(i)?.stringValue {
                                    let parts = itemStr.components(separatedBy: "|||")
                                    let title = parts.first ?? "Tab \(i-1)"
                                    let url = parts.count > 1 ? parts[1] : ""
                                    tabs.append((title: title, url: url))
                                }
                            }
                        }
                    }
                }
            }
            
            await self.updatePage(tabs: tabs, isNewTab: isNewTab, bundleID: bundleID, sessionID: sessionID)
        }
    }
    
    @MainActor
    private func updatePage(tabs: [(title: String, url: String)], isNewTab: Bool, bundleID: String, sessionID: UUID) async {
        isRefreshingTabs = false
        
        let shouldRefreshAgain = pendingRefresh
        pendingRefresh = false
        
        if shouldRefreshAgain {
            // Get the current app name since it might have changed, or we can just reuse it if we have it
            if let app = NSWorkspace.shared.frontmostApplication,
               app.bundleIdentifier == bundleID,
               let appName = getBrowserAppName(bundleID: bundleID, localizedName: app.localizedName) {
                refreshTabs(for: bundleID, appName: appName, sessionID: sessionID)
            }
        }
        
        guard sessionID == currentSessionID else { return } // ignore zombie tasks
        
        let signature = "\(isNewTab ? "NEWTAB" : "TABS")|" + tabs.map { "\($0.title)|\($0.url)" }.joined(separator: ";")
        if signature == lastTabsSignature && browserPage != nil {
            return
        }
        lastTabsSignature = signature
        let newPage = await Self.createPage(tabs: tabs, isNewTab: isNewTab, bundleID: bundleID)
        
        // Ensure the session is still valid after awaiting createPage
        guard sessionID == currentSessionID else { return }
        self.browserPage = newPage
    }
    
    private static func fetchTopSitesFromSQLite(dbPath: String) -> [(title: String, url: String)] {
        let tmpPath = NSTemporaryDirectory() + "macdeck_topsites_\(UUID().uuidString).db"
        let fm = FileManager.default
        
        try? fm.removeItem(atPath: tmpPath)
        guard (try? fm.copyItem(atPath: dbPath, toPath: tmpPath)) != nil else {
            return []
        }
        defer { try? fm.removeItem(atPath: tmpPath) }
        
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }
        
        let query = "SELECT title, url FROM top_sites ORDER BY url_rank ASC LIMIT 10;"
        var statement: OpaquePointer?
        
        var results: [(title: String, url: String)] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let titleCStr = sqlite3_column_text(statement, 0),
                   let urlCStr = sqlite3_column_text(statement, 1) {
                    var title = String(cString: titleCStr)
                    let url = String(cString: urlCStr)
                    
                    // Clean up notification counters/badges in title
                    if title.hasPrefix("(") && title.contains(")") {
                        if let closingIndex = title.firstIndex(of: ")") {
                            let nextIndex = title.index(after: closingIndex)
                            title = String(title[nextIndex...]).trimmingCharacters(in: .whitespaces)
                        }
                    }
                    if title.contains(" - ") {
                        let parts = title.components(separatedBy: " - ")
                        if let firstPart = parts.first, !firstPart.isEmpty {
                            title = firstPart
                        }
                    }
                    
                    if !url.isEmpty {
                        results.append((title: title, url: url))
                    }
                }
            }
        }
        sqlite3_finalize(statement)
        return results
    }

    private static func fetchRealTopSites(bundleID: String) -> [(title: String, url: String)] {
        var topSites: [(title: String, url: String)] = []
        
        // 1. Try SQLite Top Sites database for Chromium browsers first
        let home = FileManager.default.homeDirectoryForCurrentUser
        let topSitesRelPath: String?
        switch bundleID {
        case "com.google.Chrome":
            topSitesRelPath = "Library/Application Support/Google/Chrome/Default/Top Sites"
        case "com.brave.Browser":
            topSitesRelPath = "Library/Application Support/BraveSoftware/Brave-Browser/Default/Top Sites"
        case "com.microsoft.edgemac":
            topSitesRelPath = "Library/Application Support/Microsoft Edge/Default/Top Sites"
        case "company.thebrowser.Browser":
            topSitesRelPath = "Library/Application Support/Arc/User Data/Default/Top Sites"
        case "com.vivaldi.Vivaldi":
            topSitesRelPath = "Library/Application Support/Vivaldi/Default/Top Sites"
        case "com.operasoftware.Opera":
            topSitesRelPath = "Library/Application Support/com.operasoftware.Opera/Top Sites"
        default:
            topSitesRelPath = nil
        }
        
        if let topSitesRelPath {
            let fullPath = home.appendingPathComponent(topSitesRelPath).path
            topSites = fetchTopSitesFromSQLite(dbPath: fullPath)
        }
        
        // 2. Fallback to Bookmarks if Top Sites database returned nothing or for Safari
        if topSites.isEmpty {
            if bundleID == "com.apple.Safari" {
                let script = """
                tell application "Safari"
                    set res to {}
                    try
                        repeat with b in (every bookmark of folder "Favorites")
                            try
                                if URL of b is not missing value then
                                    set end of res to (name of b) & "|||" & (URL of b)
                                end if
                            end try
                        end repeat
                    end try
                    return res
                end tell
                """
                if let appleScript = NSAppleScript(source: script) {
                    var errorInfo: NSDictionary?
                    let descriptor = appleScript.executeAndReturnError(&errorInfo)
                    if descriptor.descriptorType == typeAEList {
                        let count = descriptor.numberOfItems
                        if count > 0 {
                            for i in 1...count {
                                if let itemStr = descriptor.atIndex(i)?.stringValue {
                                    let parts = itemStr.components(separatedBy: "|||")
                                    let title = parts.first ?? "Favorite"
                                    let url = parts.count > 1 ? parts[1] : ""
                                    if !url.isEmpty {
                                        topSites.append((title: title, url: url))
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                let relPath: String
                switch bundleID {
                case "com.google.Chrome":
                    relPath = "Library/Application Support/Google/Chrome/Default/Bookmarks"
                case "com.brave.Browser":
                    relPath = "Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks"
                case "com.microsoft.edgemac":
                    relPath = "Library/Application Support/Microsoft Edge/Default/Bookmarks"
                case "company.thebrowser.Browser":
                    relPath = "Library/Application Support/Arc/User Data/Default/Bookmarks"
                case "com.vivaldi.Vivaldi":
                    relPath = "Library/Application Support/Vivaldi/Default/Bookmarks"
                case "com.operasoftware.Opera":
                    relPath = "Library/Application Support/com.operasoftware.Opera/Bookmarks"
                default:
                    relPath = "Library/Application Support/Google/Chrome/Default/Bookmarks"
                }
                
                let bookmarkURL = home.appendingPathComponent(relPath)
                if let data = try? Data(contentsOf: bookmarkURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let roots = json["roots"] as? [String: Any] {
                    
                    var bookmarkChildren: [[String: Any]] = []
                    if let bookmarkBar = roots["bookmark_bar"] as? [String: Any],
                       let children = bookmarkBar["children"] as? [[String: Any]] {
                        bookmarkChildren.append(contentsOf: children)
                    }
                    if let other = roots["other"] as? [String: Any],
                       let children = other["children"] as? [[String: Any]] {
                        bookmarkChildren.append(contentsOf: children)
                    }
                    
                    for child in bookmarkChildren {
                        if let type = child["type"] as? String, type == "url",
                           let name = child["name"] as? String,
                           let urlStr = child["url"] as? String, !urlStr.isEmpty {
                            topSites.append((title: name, url: urlStr))
                        }
                        if topSites.count >= 10 { break }
                    }
                }
            }
        }
        
        // Fill remaining with defaults if fewer than 5 top sites
        let defaults = [
            (title: "Google", url: "https://google.com"),
            (title: "YouTube", url: "https://youtube.com"),
            (title: "Reddit", url: "https://reddit.com"),
            (title: "X (Twitter)", url: "https://x.com"),
            (title: "GitHub", url: "https://github.com")
        ]
        
        for def in defaults {
            if topSites.count >= 5 { break }
            if !topSites.contains(where: { $0.url == def.url }) {
                topSites.append(def)
            }
        }
        
        return Array(topSites.prefix(5))
    }

    static func createPage(tabs: [(title: String, url: String)], isNewTab: Bool, bundleID: String = "") async -> DeckPage {
        var tiles: [DeckTile?] = Array(repeating: nil, count: 10)
        let tabActions: [BrowserControlAction] = [.switchTab1, .switchTab2, .switchTab3, .switchTab4, .switchTab5]
        let tabSymbols = ["1.circle.fill", "2.circle.fill", "3.circle.fill", "4.circle.fill", "5.circle.fill"]
        
        if isNewTab {
            let favorites = fetchRealTopSites(bundleID: bundleID)
            
            let iconDatas = await withTaskGroup(of: (Int, Data?).self) { group -> [Int: Data] in
                for (index, fav) in favorites.enumerated() {
                    group.addTask {
                        let data = await WebsiteIconLoader.iconData(for: fav.url)
                        return (index, data)
                    }
                }
                var results = [Int: Data]()
                for await (index, data) in group {
                    if let data { results[index] = data }
                }
                return results
            }
            
            for (index, fav) in favorites.enumerated() {
                let iconData = iconDatas[index] ?? SFSymbolIconGenerator.generate(
                    symbolName: "star.fill",
                    foreground: NSColor.white,
                    background: NSColor.systemYellow
                )
                
                tiles[index] = DeckTile(
                    slotIndex: index,
                    tileType: .website(url: fav.url, name: fav.title),
                    customLabel: fav.title,
                    iconData: iconData
                )
            }
        } else {
            let tabIconDatas = await withTaskGroup(of: (Int, Data?).self) { group -> [Int: Data] in
                for (index, tab) in tabs.prefix(5).enumerated() {
                    if !tab.url.isEmpty {
                        group.addTask {
                            let data = await WebsiteIconLoader.iconData(for: tab.url)
                            return (index, data)
                        }
                    }
                }
                var results = [Int: Data]()
                for await (index, data) in group {
                    if let data { results[index] = data }
                }
                return results
            }
            
            for (index, tab) in tabs.enumerated() {
                if index >= 5 { break }
                
                let iconData = tabIconDatas[index] ?? SFSymbolIconGenerator.generate(
                    symbolName: tabSymbols[index],
                    foreground: NSColor.white,
                    background: NSColor.systemBlue
                )
                
                tiles[index] = DeckTile(
                    slotIndex: index,
                    tileType: .browserControl(action: tabActions[index]),
                    customLabel: tab.title,
                    iconData: iconData
                )
            }
            
            for i in tabs.count..<5 {
                let iconData = SFSymbolIconGenerator.generate(
                    symbolName: tabSymbols[i],
                    foreground: NSColor.white,
                    background: NSColor.systemBlue
                )
                tiles[i] = DeckTile(
                    slotIndex: i,
                    tileType: .browserControl(action: tabActions[i]),
                    customLabel: "Tab \(i+1)",
                    iconData: iconData
                )
            }
        }
        
        let controlConfigs: [(slot: Int, action: BrowserControlAction, symbol: String, label: String, color: NSColor)] = [
            (5, .back, "arrow.left", "Back", .systemGray),
            (6, .forward, "arrow.right", "Forward", .systemGray),
            (7, .refresh, "arrow.clockwise", "Refresh", .systemBlue),
            (8, .newTab, "plus", "New Tab", .systemGreen),
            (9, .closeTab, "xmark", "Close Tab", .systemRed)
        ]
        
        for config in controlConfigs {
            let iconData = SFSymbolIconGenerator.generate(
                symbolName: config.symbol,
                foreground: NSColor.white,
                background: config.color
            )
            tiles[config.slot] = DeckTile(
                slotIndex: config.slot,
                tileType: .browserControl(action: config.action),
                customLabel: config.label,
                iconData: iconData
            )
        }
        
        return DeckPage(
            id: Self.browserPageID,
            name: "Browser Controls",
            pageNumber: 0,
            tiles: tiles
        )
    }
    
    static func createFallbackPage(titles: [String]) -> DeckPage {
        let tabs = titles.map { (title: $0, url: "") }
        var tiles: [DeckTile?] = Array(repeating: nil, count: 10)
        let tabActions: [BrowserControlAction] = [.switchTab1, .switchTab2, .switchTab3, .switchTab4, .switchTab5]
        let tabSymbols = ["1.circle.fill", "2.circle.fill", "3.circle.fill", "4.circle.fill", "5.circle.fill"]
        
        for (index, tab) in tabs.enumerated() {
            if index >= 5 { break }
            let iconData = SFSymbolIconGenerator.generate(
                symbolName: tabSymbols[index],
                foreground: NSColor.white,
                background: NSColor.systemBlue
            )
            tiles[index] = DeckTile(
                slotIndex: index,
                tileType: .browserControl(action: tabActions[index]),
                customLabel: tab.title,
                iconData: iconData
            )
        }
        
        for i in tabs.count..<5 {
            let iconData = SFSymbolIconGenerator.generate(
                symbolName: tabSymbols[i],
                foreground: NSColor.white,
                background: NSColor.systemBlue
            )
            tiles[i] = DeckTile(
                slotIndex: i,
                tileType: .browserControl(action: tabActions[i]),
                customLabel: "Tab \(i+1)",
                iconData: iconData
            )
        }
        
        let controlConfigs: [(slot: Int, action: BrowserControlAction, symbol: String, label: String, color: NSColor)] = [
            (5, .back, "arrow.left", "Back", .systemGray),
            (6, .forward, "arrow.right", "Forward", .systemGray),
            (7, .refresh, "arrow.clockwise", "Refresh", .systemBlue),
            (8, .newTab, "plus", "New Tab", .systemGreen),
            (9, .closeTab, "xmark", "Close Tab", .systemRed)
        ]
        
        for config in controlConfigs {
            let iconData = SFSymbolIconGenerator.generate(
                symbolName: config.symbol,
                foreground: NSColor.white,
                background: config.color
            )
            tiles[config.slot] = DeckTile(
                slotIndex: config.slot,
                tileType: .browserControl(action: config.action),
                customLabel: config.label,
                iconData: iconData
            )
        }
        
        return DeckPage(
            id: Self.browserPageID,
            name: "Browser Controls",
            pageNumber: 0,
            tiles: tiles
        )
    }
}
