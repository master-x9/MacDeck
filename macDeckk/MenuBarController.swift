import AppKit
import LocalAuthentication

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let pageStore: PageStore
    private let deckNetworkManager: DeckNetworkManager

    private let statusItem: NSStatusItem
    private let menu: NSMenu

    private let showInDockKey = "showInDock"

    init(pageStore: PageStore, deckNetworkManager: DeckNetworkManager) {
        self.pageStore = pageStore
        self.deckNetworkManager = deckNetworkManager

        self.menu = NSMenu()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        self.menu.delegate = self

        setupStatusItem()
        constructMenu()

        let showInDock = UserDefaults.standard.object(forKey: showInDockKey) as? Bool ?? true
        if !showInDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            if let image = loadStatusBarImage() {
                button.image = image
                button.image?.isTemplate = true
            } else {
                button.title = "MD"
                NSLog("MenuBarController: Using title fallback for status item icon")
            }
            button.toolTip = "MacDeck"
        }
        statusItem.menu = menu
    }

    private func loadStatusBarImage() -> NSImage? {
        if let image = NSImage(named: "MenuBarIcon") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        if let sysImage = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "MacDeck") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            return sysImage.withSymbolConfiguration(config)
        }
        return nil
    }

    private func constructMenu() {
        menu.removeAllItems()

        // Open MacDeck
        let openItem = NSMenuItem(title: "Open MacDeck", action: #selector(openMacDeck), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // Start at Login - checkable
        let startAtLoginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        startAtLoginItem.target = self
        startAtLoginItem.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        menu.addItem(startAtLoginItem)

        // Show Running Apps - checkable
        let showRunningAppsItem = NSMenuItem(title: "Show Running Apps", action: #selector(toggleShowRunningApps), keyEquivalent: "")
        showRunningAppsItem.target = self
        showRunningAppsItem.state = pageStore.showRunningAppsPage ? .on : .off
        menu.addItem(showRunningAppsItem)

        // Allow Unlock from Phone - checkable, requires authentication and password prompt if enabling
        let allowUnlockItem = NSMenuItem(title: "Allow Unlock from Phone", action: #selector(toggleAllowUnlockFromPhone), keyEquivalent: "")
        allowUnlockItem.target = self
        allowUnlockItem.state = RemoteUnlockManager.shared.isEnabled ? .on : .off
        menu.addItem(allowUnlockItem)

        // Show in Dock - checkable, toggling activation policy and saving flag
        let showInDockItem = NSMenuItem(title: "Show in Dock", action: #selector(toggleShowInDock), keyEquivalent: "")
        showInDockItem.target = self
        let showInDock = UserDefaults.standard.object(forKey: showInDockKey) as? Bool ?? true
        showInDockItem.state = showInDock ? .on : .off
        menu.addItem(showInDockItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == self.menu else { return }
        LaunchAtLoginManager.shared.refreshStatus()
        if let startAtLoginItem = menu.item(withTitle: "Start at Login") {
            startAtLoginItem.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        }
        if let showRunningAppsItem = menu.item(withTitle: "Show Running Apps") {
            showRunningAppsItem.state = pageStore.showRunningAppsPage ? .on : .off
        }
        if let allowUnlockItem = menu.item(withTitle: "Allow Unlock from Phone") {
            allowUnlockItem.state = RemoteUnlockManager.shared.isEnabled ? .on : .off
        }
        if let showInDockItem = menu.item(withTitle: "Show in Dock") {
            let showInDock = UserDefaults.standard.object(forKey: showInDockKey) as? Bool ?? true
            showInDockItem.state = showInDock ? .on : .off
        }
    }

    // MARK: - Menu Actions

    @objc private func toggleStartAtLogin() {
        LaunchAtLoginManager.shared.toggle()
        menu.update()
    }

    @objc private func openMacDeck() {
        NSApp.activate(ignoringOtherApps: true)
        
        var foundWindow = false
        for window in NSApp.windows {
            if window.title == "MacDeck" {
                window.makeKeyAndOrderFront(nil)
                foundWindow = true
                break
            }
        }
        
        if !foundWindow {
            // Attempt to trigger the standard SwiftUI reopen behavior
            if let delegate = NSApp.delegate {
                _ = delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            }
            
            // As a fallback, trigger NSWorkspace open
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config, completionHandler: nil)
        }
    }

    @objc private func toggleShowRunningApps() {
        pageStore.showRunningAppsPage.toggle()
        deckNetworkManager.broadcastPageUpdate()
    }

    @objc private func toggleAllowUnlockFromPhone() {
        Task {
            if RemoteUnlockManager.shared.isEnabled {
                RemoteUnlockManager.shared.disable()
            } else {
                guard await authenticateUser() else { return }
                guard let password = await promptForPassword() else { return }

                do {
                    try RemoteUnlockManager.shared.enable(password: password)
                } catch {
                    NSLog("PhoneDeck: Failed to enable remote unlock from menu bar: \(error)")
                }
            }
            deckNetworkManager.broadcastPageUpdate()
        }
    }

    @objc private func toggleShowInDock() {
        let currentlyShown = UserDefaults.standard.object(forKey: showInDockKey) as? Bool ?? true
        let newShowInDock = !currentlyShown
        UserDefaults.standard.set(newShowInDock, forKey: showInDockKey)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(newShowInDock ? .regular : .accessory)
        }
        menu.update()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Authentication & Password Prompt

    private func authenticateUser() async -> Bool {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            var error: NSError?

            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Authenticate to allow unlock from phone") { success, _ in
                    continuation.resume(returning: success)
                }
            } else {
                continuation.resume(returning: false)
            }
        }
    }

    private func promptForPassword() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Enter password to allow unlock from phone"
                alert.alertStyle = .informational

                let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                alert.accessoryView = input

                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()

                if response == .alertFirstButtonReturn, let password = input.stringValue.isEmpty ? nil : input.stringValue {
                    continuation.resume(returning: password)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
