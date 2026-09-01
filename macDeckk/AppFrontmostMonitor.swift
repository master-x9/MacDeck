//
//  AppFrontmostMonitor.swift
//  MacDeck (macOS Host)
//
//  Single shared source of truth for "what app is frontmost" and "what
//  apps are running". OBSControlManager, DiscordControlManager, and the
//  per-page app-trigger feature all need this same information — routing
//  them through one NSWorkspace observer instead of each adding their own
//  keeps the app from doing the same notification-center bookkeeping three
//  times over.
//

import AppKit
import Combine

@MainActor
final class AppFrontmostMonitor: ObservableObject {
    static let shared = AppFrontmostMonitor()

    /// Bundle ID of the current frontmost app, if any.
    @Published private(set) var frontmostBundleID: String?

    /// Bundle IDs of every currently-running app (regular + background),
    /// refreshed on launch/terminate. Used for "is OBS even open" checks
    /// that shouldn't require OBS to be frontmost.
    @Published private(set) var runningBundleIDs: Set<String> = []

    private init() {
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(runningAppsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(runningAppsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func isRunning(_ bundleID: String) -> Bool {
        runningBundleIDs.contains(bundleID)
    }

    @objc nonisolated private func appActivated(_ note: Notification) {
        let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        Task { @MainActor in
            self.frontmostBundleID = bundleID
        }
    }

    @objc nonisolated private func runningAppsChanged(_ note: Notification) {
        Task { @MainActor in
            self.runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        }
    }
}
