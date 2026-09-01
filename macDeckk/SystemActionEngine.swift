//
//  SystemActionEngine.swift
//  MacDeck (macOS Host)
//
//  Executes whatever a tile represents: launching an app, opening a
//  website, or firing a system control (media keys, brightness, lock,
//  Mission Control, etc). This is the thing DeckNetworkManager calls
//  into when a TRIGGER_SLOT message arrives from the phone.
//

import AppKit
import ApplicationServices
import IOKit.pwr_mgt

@MainActor
final class SystemActionEngine {

    static let shared = SystemActionEngine()

    /// True once the user has granted Accessibility access. Media keys,
    /// Mission Control, and quit-frontmost-app all require this.
    private(set) var hasAccessibilityPermission = false

    /// IOPMAssertion used to implement the "Keep Awake" toggle tile.
    private var keepAwakeAssertionID: IOPMAssertionID?
    private(set) var isKeepAwakeActive = false

    private init() {
        refreshAccessibilityPermission(prompt: false)
    }

    // MARK: - Permissions

    /// Checks (and optionally prompts for) Accessibility access.
    /// Call with `prompt: true` from a user-initiated "grant access" flow;
    /// call with `prompt: false` on launch / app-foreground to just refresh state.
    @discardableResult
    func refreshAccessibilityPermission(prompt: Bool) -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = isTrusted

        // If we prompted but it's still not trusted or we just want to force open the UI if prompt is true
        if prompt && !isTrusted {
            let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }

        return hasAccessibilityPermission
    }

    // MARK: - Entry point

    /// Executes a tile's action. Call this from the network layer when a
    /// TRIGGER_SLOT command comes in, or directly from the UI for local testing.
    func execute(_ type: TileType) {
        switch type {
        case .app(let bundleID, _):
            launchApp(bundleIdentifier: bundleID)
        case .systemControl(let action):
            performSystemControl(action)
        case .browserControl(let action):
            performBrowserControl(action)
        case .website(let urlString, _):
            openWebsite(urlString)
        case .shortcut(let name):
            if name.hasPrefix("MACRO|") {
                executeMacro(name)
            } else {
                runShortcut(named: name)
            }
        case .obsControl(let action):
            OBSControlManager.shared.execute(action)
        case .discordControl(let action):
            DiscordControlManager.shared.execute(action)
        }
    }

    private func executeMacro(_ macroString: String) {
        guard requireAccessibility() else { return }
        
        let components = macroString.components(separatedBy: "|")
        guard components.count >= 3,
              let keyCode = UInt16(components[1]),
              let flagsRaw = UInt64(components[2]) else {
            NSLog("PhoneDeck: Invalid macro string: \(macroString)")
            return
        }
        
        let flags = CGEventFlags(rawValue: flagsRaw)
        injectMacro(key: keyCode, flags: flags)
    }

    // MARK: - App launching

    func launchApp(bundleIdentifier: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            NSLog("PhoneDeck: could not resolve app for bundle id \(bundleIdentifier)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                NSLog("PhoneDeck: failed to launch \(bundleIdentifier): \(error)")
            }
        }
    }

    /// Scans /Applications and /System/Applications for the tile library picker.
    /// Returns (bundle identifier, display name, icon) tuples.
    nonisolated func discoverInstalledApps() -> [(bundleID: String, name: String, icon: NSImage)] {
        let fm = FileManager.default
        let searchDirs = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications")]
        var results: [(String, String, NSImage)] = []

        for dir in searchDirs {
            let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: options) else { continue }
            
            for case let url as URL in enumerator {
                if url.pathExtension == "app" {
                    guard let bundle = Bundle(url: url),
                          let bundleID = bundle.bundleIdentifier else { continue }
                    let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: 44, height: 44)
                    results.append((bundleID, name, icon))
                }
            }
        }
        return results.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    // MARK: - Websites

    func openWebsite(_ urlString: String) {
        var normalized = urlString
        if !normalized.lowercased().hasPrefix("http://") && !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }
        guard let url = URL(string: normalized) else {
            NSLog("PhoneDeck: invalid website URL \(urlString)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Shortcuts (macOS Shortcuts.app)

    func runShortcut(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        do {
            try process.run()
        } catch {
            NSLog("PhoneDeck: failed to run shortcut '\(name)': \(error)")
        }
    }

    // MARK: - System controls

    func performSystemControl(_ action: SystemControlAction) {
        switch action {
        case .brightnessUp:
            postMediaKey(NX_KEYTYPE_BRIGHTNESS_UP)
        case .brightnessDown:
            postMediaKey(NX_KEYTYPE_BRIGHTNESS_DOWN)
        case .kbBrightnessUp:
            postMediaKey(NX_KEYTYPE_ILLUMINATION_UP)
        case .kbBrightnessDown:
            postMediaKey(NX_KEYTYPE_ILLUMINATION_DOWN)
        case .playPause:
            postMediaKey(NX_KEYTYPE_PLAY)
        case .nextTrack:
            postMediaKey(NX_KEYTYPE_NEXT)
        case .previousTrack:
            postMediaKey(NX_KEYTYPE_PREVIOUS)
        case .mute:
            postMediaKey(NX_KEYTYPE_MUTE)
        case .volumeUp:
            postMediaKey(NX_KEYTYPE_SOUND_UP)
        case .volumeDown:
            postMediaKey(NX_KEYTYPE_SOUND_DOWN)
        case .screenshot:
            captureScreenshot()
        case .screenRecord:
            captureScreenRecording()
        case .keepAwake:
            toggleKeepAwake()
        case .quitFrontmostApp:
            quitFrontmostApp()
        case .lockScreen:
            lockScreen()
        case .sleepMac:
            sleepMac()
        case .desktop:
            showDesktop()
        case .missionControl:
            showMissionControl()
        case .emptyTrash:
            emptyTrash()
        case .unlockMac:
            Task { @MainActor in
                await RemoteUnlockManager.shared.attemptUnlock()
            }
        case .dnd:
            toggleDND()
        }
    }

    func performBrowserControl(_ action: BrowserControlAction) {
        guard requireAccessibility() else { return }
        switch action {
        case .switchTab1: injectShortcut(key: 18, flags: .maskCommand) // '1'
        case .switchTab2: injectShortcut(key: 19, flags: .maskCommand) // '2'
        case .switchTab3: injectShortcut(key: 20, flags: .maskCommand) // '3'
        case .switchTab4: injectShortcut(key: 21, flags: .maskCommand) // '4'
        case .switchTab5: injectShortcut(key: 23, flags: .maskCommand) // '5'
        case .back: injectShortcut(key: 33, flags: .maskCommand) // '['
        case .forward: injectShortcut(key: 30, flags: .maskCommand) // ']'
        case .refresh: injectShortcut(key: 15, flags: .maskCommand) // 'R'
        case .newTab: injectShortcut(key: 17, flags: .maskCommand) // 'T'
        case .closeTab: injectShortcut(key: 13, flags: .maskCommand) // 'W'
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NotificationCenter.default.post(name: NSNotification.Name("triggerBrowserTabRefresh"), object: nil)
        }
    }
    
    private func injectShortcut(key: CGKeyCode, flags: CGEventFlags) {
        Task.detached(priority: .userInitiated) {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) else { return }
            keyDown.flags = flags
            keyDown.post(tap: .cghidEventTap)
            
            try? await Task.sleep(nanoseconds: 10_000_000)
            
            guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
            keyUp.flags = flags
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func injectMacro(key: CGKeyCode, flags: CGEventFlags) {
        var modifiers: [String] = []
        if flags.contains(.maskCommand) { modifiers.append("command down") }
        if flags.contains(.maskAlternate) { modifiers.append("option down") }
        if flags.contains(.maskControl) { modifiers.append("control down") }
        if flags.contains(.maskShift) { modifiers.append("shift down") }
        
        let usingClause = modifiers.isEmpty ? "" : " using {\(modifiers.joined(separator: ", "))}"
        let script = "tell application \"System Events\" to key code \(key)\(usingClause)"
        
        DispatchQueue.main.async {
            self.runAppleScript(script)
        }
    }

    // MARK: - Media key injection (requires Accessibility)

    /// Posts a synthetic NX system-defined key event, e.g. NX_KEYTYPE_PLAY.
    /// This is the standard trick apps like Stream Deck / MonitorControl use
    /// since there's no public API for triggering media/brightness keys directly.
    private func postMediaKey(_ key: Int32) {
        guard requireAccessibility() else { return }
        Task.detached(priority: .userInitiated) {
            Self.postMediaKeyEvent(key, keyDown: true)
            try? await Task.sleep(nanoseconds: 50_000_000)
            Self.postMediaKeyEvent(key, keyDown: false)
        }
    }

    nonisolated private static func postMediaKeyEvent(_ key: Int32, keyDown: Bool) {
        let flags: NSEvent.ModifierFlags = keyDown ? NSEvent.ModifierFlags(rawValue: 0xa00) : NSEvent.ModifierFlags(rawValue: 0xb00)
        let data1 = Int((key << 16) | (Int32(keyDown ? 0xa : 0xb) << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cgSessionEventTap)
        #if DEBUG
        NSLog("PhoneDeck: injected media key \(key) (down: \(keyDown))")
        #endif
    }

    // MARK: - Accessibility-gated system actions

    private func quitFrontmostApp() {
        guard requireAccessibility() else { return }
        injectShortcut(key: 12, flags: .maskCommand) // Cmd+Q
    }

    private func showMissionControl() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Mission Control"]
        try? process.run()
    }

    private func showDesktop() {
        guard requireAccessibility() else { return }
        let script = """
        tell application "System Events"
            key code 160 using command down
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("PhoneDeck: Failed to show Desktop via AppleScript: \(error)")
            }
        }
    }
    
    private func toggleDND() {
        guard requireAccessibility() else { return }
        let script = """
        tell application "System Events"
            key code 178
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("PhoneDeck: Failed to toggle DND via AppleScript: \(error)")
                injectShortcut(key: 178, flags: [])
            }
        } else {
            injectShortcut(key: 178, flags: [])
        }
    }

    private func emptyTrash() {
        guard requireAccessibility() else { return }
        injectShortcut(key: 51, flags: [.maskCommand, .maskShift, .maskAlternate]) // Cmd+Shift+Opt+Delete
    }

    private func captureScreenshot() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let dateString = dateFormatter.string(from: Date())
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/Screenshot_\(dateString).png")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [path]
        try? process.run()
        NSLog("PhoneDeck: Screenshot saved to \(path)")
    }

    private var screenRecordTask: Process?

    private func captureScreenRecording() {
        if let task = screenRecordTask {
            task.interrupt() // Sends SIGINT, finalizing the recording
            task.waitUntilExit()
            screenRecordTask = nil
            NSLog("PhoneDeck: Stopped screen recording")
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
            let dateString = dateFormatter.string(from: Date())
            let path = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/ScreenRecording_\(dateString).mov")
            
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-v", path] // -v captures video
            try? task.run()
            screenRecordTask = task
            NSLog("PhoneDeck: Started screen recording to \(path)")
        }
    }

    private func lockScreen() {
        guard requireAccessibility() else { return }
        injectShortcut(key: 12, flags: [.maskCommand, .maskControl]) // Cmd+Ctrl+Q
    }

    private func sleepMac() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        try? process.run()
    }

    private var caffeinateTask: Process?
    
    private func toggleKeepAwake() {
        if isKeepAwakeActive {
            caffeinateTask?.terminate()
            caffeinateTask = nil
            isKeepAwakeActive = false
            NSLog("PhoneDeck: Disabled Caffeinate")
        } else {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            task.arguments = ["-d"] // prevent display sleep
            try? task.run()
            caffeinateTask = task
            isKeepAwakeActive = true
            NSLog("PhoneDeck: Enabled Caffeinate")
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func requireAccessibility() -> Bool {
        if !hasAccessibilityPermission {
            refreshAccessibilityPermission(prompt: false)
        }
        if !hasAccessibilityPermission {
            NotificationCenter.default.post(name: .phoneDeckNeedsAccessibility, object: nil)
        }
        return hasAccessibilityPermission
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&errorDict)
        if let errorDict {
            NSLog("PhoneDeck: AppleScript error \(errorDict)")
            return false
        }
        return true
    }
}

extension Notification.Name {
    /// Posted when an action needs Accessibility permission but it hasn't been granted.
    /// The UI layer observes this to show the "Open Settings" banner seen in the app.
    static let phoneDeckNeedsAccessibility = Notification.Name("phoneDeckNeedsAccessibility")
}
