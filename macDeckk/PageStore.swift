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
    let obsMonitor = OBSControlManager.shared
    let discordMonitor = DiscordControlManager.shared
    private var cancellables = Set<AnyCancellable>()

    @Published var pages: [DeckPage] {
        didSet { save() }
    }
    @Published var selectedPageID: UUID? {
        didSet {
            if let newID = selectedPageID, pages.contains(where: { $0.id == newID }) {
                previousNonDynamicPageID = newID
            }
        }
    }
    var previousNonDynamicPageID: UUID?
    
    @Published var showRunningAppsPage: Bool = true {
        didSet {
            UserDefaults.standard.set(showRunningAppsPage, forKey: "phonedeck.showRunningAppsPage")
            runningAppsMonitor.isEnabled = showRunningAppsPage
            if !showRunningAppsPage && isRunningAppsSelected {
                selectedPageID = previousNonDynamicPageID ?? pages.first?.id
            }
        }
    }
    
    @Published var showBrowserControlPage: Bool = true {
        didSet {
            UserDefaults.standard.set(showBrowserControlPage, forKey: "phonedeck.showBrowserControlPage")
            if !showBrowserControlPage && isBrowserControlSelected {
                selectedPageID = previousNonDynamicPageID ?? pages.first?.id
            }
        }
    }

    @Published var showOBSPage: Bool = true {
        didSet {
            UserDefaults.standard.set(showOBSPage, forKey: "phonedeck.showOBSPage")
            if !showOBSPage && isOBSSelected {
                selectedPageID = previousNonDynamicPageID ?? pages.first?.id
            }
        }
    }

    @Published var showDiscordPage: Bool = true {
        didSet {
            UserDefaults.standard.set(showDiscordPage, forKey: "phonedeck.showDiscordPage")
            DiscordCalls.shared.enabled = showDiscordPage
            if !showDiscordPage && (isDiscordSelected || selectedPageID == DiscordCalls.pageID) {
                selectedPageID = previousNonDynamicPageID ?? pages.first?.id
            }
        }
    }

    @Published var gridRows: Int = 2

    /// The page currently shown in the phone-frame preview (and sent to the phone).
    var activePage: DeckPage? {
        if showBrowserControlPage, let bp = browserMonitor.browserPage, selectedPageID == BrowserMonitor.browserPageID {
            return bp
        }
        if showRunningAppsPage && selectedPageID == RunningAppsMonitor.runningAppsPageID {
            return runningAppsMonitor.runningAppsPage
        }
        if showOBSPage, let op = obsMonitor.obsPage, selectedPageID == OBSControlManager.obsPageID {
            return op
        }
        if showDiscordPage, selectedPageID == DiscordCalls.pageID { return DiscordCalls.shared.page }
        if showDiscordPage, let dp = discordMonitor.discordPage, selectedPageID == DiscordControlManager.discordPageID {
            return dp
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
        if showOBSPage, let op = obsMonitor.obsPage {
            list.append(op)
        }
        if showDiscordPage, let dp = discordMonitor.discordPage {
            list.append(dp)
        }
        if showDiscordPage, let call = DiscordCalls.shared.page { list.append(call) }
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

    /// Whether the OBS page is currently selected.
    var isOBSSelected: Bool {
        selectedPageID == OBSControlManager.obsPageID
    }

    /// Whether the Discord page is currently selected.
    var isDiscordSelected: Bool {
        selectedPageID == DiscordControlManager.discordPageID
    }

    /// Resolves which page (if any) should be auto-shown on the phone
    /// because `bundleID` just became the frontmost app on the Mac. Checks
    /// the built-in OBS/Discord pages first (only while they actually have
    /// live data to show), then any user page with a matching entry in
    /// `triggerBundleIDs`. Returns nil when nothing should change.
    func autoSwitchPageID(forFrontmostBundleID bundleID: String?) -> UUID? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if showOBSPage, bundleID == OBSControlManager.obsBundleID, obsMonitor.obsPage != nil {
            return OBSControlManager.obsPageID
        }
        if showDiscordPage, bundleID == DiscordControlManager.discordBundleID, DiscordCalls.shared.page != nil { return DiscordCalls.pageID }
        if showDiscordPage, bundleID == DiscordControlManager.discordBundleID, discordMonitor.discordPage != nil {
            return DiscordControlManager.discordPageID
        }
        return pages.first { $0.triggerBundleIDs.contains(bundleID) }?.id
    }

    /// Sets (or clears, with an empty array) which apps auto-switch the
    /// phone to a given page. See `DeckPage.triggerBundleIDs`.
    func setTriggerBundleIDs(_ bundleIDs: [String], forPage pageID: UUID) {
        guard let idx = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[idx].triggerBundleIDs = bundleIDs
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
            "phonedeck.showBrowserControlPage": true,
            "phonedeck.showOBSPage": true,
            "phonedeck.showDiscordPage": true,
        ])
        self.showRunningAppsPage = UserDefaults.standard.bool(forKey: "phonedeck.showRunningAppsPage")
        self.showBrowserControlPage = UserDefaults.standard.bool(forKey: "phonedeck.showBrowserControlPage")
        self.showOBSPage = UserDefaults.standard.bool(forKey: "phonedeck.showOBSPage")
        self.showDiscordPage = UserDefaults.standard.bool(forKey: "phonedeck.showDiscordPage")
        
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
                    self.selectedPageID = self.previousNonDynamicPageID ?? self.pages.first?.id
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        DiscordCalls.shared.enabled = showDiscordPage
        DiscordCalls.shared.$page.sink { [weak self] page in
            guard let self else { return }
            if page == nil && self.selectedPageID == DiscordCalls.pageID { self.selectedPageID = self.previousNonDynamicPageID ?? self.pages.first?.id }
            self.objectWillChange.send()
        }.store(in: &cancellables)

        obsMonitor.$obsPage
            .sink { [weak self] newPage in
                guard let self else { return }
                if newPage == nil && self.selectedPageID == OBSControlManager.obsPageID {
                    self.selectedPageID = self.previousNonDynamicPageID ?? self.pages.first?.id
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        discordMonitor.$discordPage
            .sink { [weak self] newPage in
                guard let self else { return }
                if newPage == nil && self.selectedPageID == DiscordControlManager.discordPageID {
                    self.selectedPageID = self.previousNonDynamicPageID ?? self.pages.first?.id
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        self.previousNonDynamicPageID = self.selectedPageID
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

                // If icon already present, keep it.
                if tile.iconData != nil { return tile }

                switch tile.tileType {
                case .app(let bundleID, _):
                    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                        tile.iconData = icon.pngData(size: CGSize(width: 128, height: 128))
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
                    // Leave nil here so populateMissingWebsiteIcons() can fetch a favicon async.
                    // Provide a temporary fallback so the phone has something to render until then.
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
                case .obsControl(let action):
                    tile.iconData = SFSymbolIconGenerator.generate(
                        symbolName: action.defaultSystemImageName,
                        foreground: NSColor.white,
                        background: NSColor.systemRed
                    )
                case .discordControl(let action):
                    tile.iconData = SFSymbolIconGenerator.generate(
                        symbolName: action.defaultSystemImageName,
                        foreground: NSColor.white,
                        background: NSColor(calibratedRed: 0.345, green: 0.396, blue: 0.949, alpha: 1)
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
                      case .website(let url, _) = tile.tileType,
                      let iconData = await WebsiteIconLoader.iconData(for: url) else {
                    continue
                }

                if tile.iconData != iconData {
                    tile.iconData = iconData
                    updatedPages[pageIndex].tiles[tileIndex] = tile
                    didUpdate = true
                }
            }
        }

        if didUpdate {
            pages = updatedPages
            save()
            objectWillChange.send()
        }
    }

    private let saveQueue = DispatchQueue(label: "com.macdeck.pagestore.save", qos: .utility)
    private var saveWorkItem: DispatchWorkItem?

    private func save() {
        #if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
        #endif
        let pagesCopy = self.pages
        let url = Self.storageURL

        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            #if DEBUG
            let workStart = CFAbsoluteTimeGetCurrent()
            #endif
            do {
                let data = try JSONEncoder().encode(pagesCopy)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("MacDeck: failed to persist pages: \(error)")
            }
            #if DEBUG
            let workEnd = CFAbsoluteTimeGetCurrent()
            NSLog("MacDeck: Background save took \((workEnd - workStart) * 1000)ms")
            #endif
        }
        saveWorkItem = workItem
        saveQueue.async(execute: workItem)
        #if DEBUG
        let end = CFAbsoluteTimeGetCurrent()
        NSLog("MacDeck: Foreground save dispatch took \((end - start) * 1000)ms")
        #endif
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
        if previousNonDynamicPageID == pageID {
            previousNonDynamicPageID = pages.first?.id
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
        #if DEBUG
        let assignStart = CFAbsoluteTimeGetCurrent()
        #endif
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
                if let cached = WebsiteIconLoader.cachedIconData(for: url) {
                    updatedTile.iconData = cached
                } else {
                    updatedTile.iconData = SFSymbolIconGenerator.generate(
                        symbolName: "globe",
                        foreground: NSColor.white,
                        background: NSColor.systemBlue
                    )
                }
                pages[idx].tiles[slot] = updatedTile
                broadcastUpdate?()

                if WebsiteIconLoader.cachedIconData(for: url) == nil {
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
            case .obsControl(let action):
                // Not user-placeable from the Library today (OBS tiles are
                // auto-generated by OBSControlManager, which always sets
                // iconData itself) — handled here anyway so this switch
                // stays exhaustive and safe if that ever changes.
                updatedTile.iconData = SFSymbolIconGenerator.generate(
                    symbolName: action.defaultSystemImageName,
                    foreground: NSColor.white,
                    background: NSColor.systemRed
                )
            case .discordControl(let action):
                updatedTile.iconData = SFSymbolIconGenerator.generate(
                    symbolName: action.defaultSystemImageName,
                    foreground: NSColor.white,
                    background: NSColor(calibratedRed: 0.345, green: 0.396, blue: 0.949, alpha: 1)
                )
            }
        }

        pages[idx].tiles[slot] = updatedTile
        broadcastUpdate?()
        #if DEBUG
        let end = CFAbsoluteTimeGetCurrent()
        NSLog("MacDeck: assignTile took \((end - assignStart) * 1000)ms")
        #endif
    }

    /// Assigns a tile built from an app entry (with icon encoding baked in).
    func assignAppTile(bundleID: String, name: String, icon: NSImage, toSlot slot: Int, broadcastUpdate: (() -> Void)? = nil) {
        let iconData = icon.pngData(size: CGSize(width: 128, height: 128))
        let tile = DeckTile(
            slotIndex: slot,
            tileType: .app(bundleIdentifier: bundleID, name: name),
            iconData: iconData
        )
        assignTile(tile, toSlot: slot, broadcastUpdate: broadcastUpdate)
    }

    func removeTile(atSlot slot: Int, broadcastUpdate: (() -> Void)? = nil) {
        #if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
        #endif
        guard let idx = activePageIndex, slot >= 0, slot < DeckPage.slotCount else { return }
        pages[idx].tiles[slot] = nil
        broadcastUpdate?()
        #if DEBUG
        let end = CFAbsoluteTimeGetCurrent()
        NSLog("MacDeck: removeTile took \((end - start) * 1000)ms")
        #endif
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
    private static var cache = [String: Data]()
    private static let lock = NSLock()

    static func generate(symbolName: String, foreground: NSColor, background: NSColor, size: CGSize = CGSize(width: 128, height: 128)) -> Data? {
        let key = "\(symbolName)|\(foreground.description)|\(background.description)|\(size.width)x\(size.height)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: size.width * 0.15, yRadius: size.height * 0.15)
            background.setFill()
            path.fill()

            if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                .flatMap({ $0.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size.width * 0.5, weight: .regular).applying(.init(hierarchicalColor: foreground))) }) {
                    let drawRect = NSRect(
                        x: (size.width - symbolImage.size.width) / 2,
                        y: (size.height - symbolImage.size.height) / 2,
                        width: symbolImage.size.width,
                        height: symbolImage.size.height
                    )
                    symbolImage.draw(in: drawRect)
            }
            return true
        }

        let result = image.pngData(size: size)
        if let result {
            lock.lock()
            cache[key] = result
            lock.unlock()
        }
        return result
    }
}


@MainActor
final class BrowserMonitor: ObservableObject {
    static let browserPageID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    
    @Published private(set) var browserPage: DeckPage?
    
    // Internal state to prevent AppleScript polling from stacking up and causing massive delays
    private var isRefreshingTabs = false
    
    private var timer: Timer?
    private var currentSessionID = UUID()
    private var lastTabsSignature: String = ""
    private var lastTabs: [(title: String, url: String)] = []
    private var lastIsNewTab: Bool = false
    private var lastBundleID: String = ""
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
        
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
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
        guard !isRefreshingTabs else { return }
        isRefreshingTabs = true
        
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
    private func updatePage(tabs: [(title: String, url: String)], isNewTab: Bool, bundleID: String, sessionID: UUID) {
        isRefreshingTabs = false
        guard sessionID == currentSessionID else { return } // ignore zombie tasks

        let signature = "\(isNewTab ? "NEWTAB" : "TABS")|" + tabs.map { "\($0.title)|\($0.url)" }.joined(separator: ";")
        if signature == lastTabsSignature && browserPage != nil {
            return
        }
        lastTabsSignature = signature
        self.lastTabs = tabs
        self.lastIsNewTab = isNewTab
        self.lastBundleID = bundleID
        let newPage = Self.createPage(tabs: tabs, isNewTab: isNewTab, bundleID: bundleID) { [weak self] in
            Task { @MainActor in
                self?.rebuildCurrentPage()
            }
        }

        // Ensure the session is still valid after creating page
        guard sessionID == currentSessionID else { return }
        self.browserPage = newPage
    }
    
    @MainActor
    private func rebuildCurrentPage() {
        guard browserPage != nil else { return }
        self.browserPage = Self.createPage(tabs: lastTabs, isNewTab: lastIsNewTab, bundleID: lastBundleID) { [weak self] in
            Task { @MainActor in
                self?.rebuildCurrentPage()
            }
        }
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

    static func createPage(tabs: [(title: String, url: String)], isNewTab: Bool, bundleID: String = "", onFaviconLoaded: (() -> Void)? = nil) -> DeckPage {
        // Was hardcoded to 10 — a stale assumption from when DeckPage.slotCount
        // was 10. Left as-is it under-sized this page's tiles array relative
        // to every other page (now 20 slots), which would crash or silently
        // truncate anywhere code indexes tiles up to DeckPage.slotCount - 1.
        var tiles: [DeckTile?] = Array(repeating: nil, count: DeckPage.slotCount)
        let tabActions: [BrowserControlAction] = [.switchTab1, .switchTab2, .switchTab3, .switchTab4, .switchTab5]
        let tabSymbols = ["1.circle.fill", "2.circle.fill", "3.circle.fill", "4.circle.fill", "5.circle.fill"]

        if isNewTab {
            let favorites = fetchRealTopSites(bundleID: bundleID)

            for (index, fav) in favorites.enumerated() {
                var iconData = WebsiteIconLoader.cachedIconData(for: fav.url)
                if iconData == nil {
                    iconData = SFSymbolIconGenerator.generate(
                        symbolName: "star.fill",
                        foreground: NSColor.white,
                        background: NSColor.systemYellow
                    )
                    Task {
                        if await WebsiteIconLoader.iconData(for: fav.url) != nil {
                            onFaviconLoaded?()
                        }
                    }
                }

                tiles[index] = DeckTile(
                    slotIndex: index,
                    tileType: .website(url: fav.url, name: fav.title),
                    customLabel: fav.title,
                    iconData: iconData
                )
            }
        } else {
            for (index, tab) in tabs.enumerated() {
                if index >= 5 { break }

                var iconData: Data? = nil
                if !tab.url.isEmpty {
                    iconData = WebsiteIconLoader.cachedIconData(for: tab.url)
                    if iconData == nil {
                        Task {
                            if await WebsiteIconLoader.iconData(for: tab.url) != nil {
                                onFaviconLoaded?()
                            }
                        }
                    }
                }
                if iconData == nil {
                    iconData = SFSymbolIconGenerator.generate(
                        symbolName: tabSymbols[index],
                        foreground: NSColor.white,
                        background: NSColor.systemBlue
                    )
                }

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
        var tiles: [DeckTile?] = Array(repeating: nil, count: DeckPage.slotCount)
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
