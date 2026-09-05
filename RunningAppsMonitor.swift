import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class RunningAppsMonitor: ObservableObject {
    static let runningAppsPageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Published var runningAppsPage: DeckPage = DeckPage(
        id: RunningAppsMonitor.runningAppsPageID,
        name: "Running Apps",
        pageNumber: 0,
        tiles: Array(repeating: nil, count: DeckPage.slotCount)
    )

    /// Set by PageStore to mirror `showRunningAppsPage`. While false, the
    /// timer still fires but does no work — avoids polling/rendering icons
    /// in the background for a page the user has turned off.
    var isEnabled: Bool = true {
        didSet {
            guard isEnabled, !oldValue else { return }
            refresh() // catch up immediately on re-enable
        }
    }

    private var timer: Timer?
    private var lastAppBundleIDs: [String] = []
    private var isRefreshing = false

    init() {
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunchedOrTerminated),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunchedOrTerminated),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc nonisolated private func appLaunchedOrTerminated(_ notification: Notification) {
        Task { @MainActor in
            self.refresh()
        }
    }

    func refresh() {
        guard isEnabled, !isRefreshing else { return }

        let runningApps = Array(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .prefix(DeckPage.slotCount))

        let currentBundleIDs = runningApps.compactMap { $0.bundleIdentifier }

        if currentBundleIDs == lastAppBundleIDs && runningAppsPage.tiles.compactMap({ $0 }).count == currentBundleIDs.count {
            return
        }

        lastAppBundleIDs = currentBundleIDs
        isRefreshing = true

        // Read what we need from each NSRunningApplication on the main actor
        // (these properties should be touched on main), then hand the actual
        // icon rendering + PNG encoding — the expensive part — to a
        // background task so a burst of app launches never stutters the UI.
        struct AppInfo { let index: Int; let bundleIdentifier: String; let name: String; let bundleURL: URL }
        let infos: [AppInfo] = runningApps.enumerated().compactMap { index, app in
            guard let bundleIdentifier = app.bundleIdentifier,
                  let name = app.localizedName,
                  let bundleURL = app.bundleURL else { return nil }
            return AppInfo(index: index, bundleIdentifier: bundleIdentifier, name: name, bundleURL: bundleURL)
        }

        Task.detached(priority: .utility) {
            var tiles: [DeckTile?] = Array(repeating: nil, count: DeckPage.slotCount)
            for info in infos {
                let icon = NSWorkspace.shared.icon(forFile: info.bundleURL.path)
                let iconData = icon.pngData(size: CGSize(width: 144, height: 144))
                tiles[info.index] = DeckTile(
                    slotIndex: info.index,
                    tileType: .app(bundleIdentifier: info.bundleIdentifier, name: info.name),
                    customLabel: info.name,
                    iconData: iconData
                )
            }

            await MainActor.run { [tiles] in
                self.runningAppsPage = DeckPage(
                    id: Self.runningAppsPageID,
                    name: "Running Apps",
                    pageNumber: 0,
                    tiles: tiles
                )
                self.isRefreshing = false
            }
        }
    }
}
