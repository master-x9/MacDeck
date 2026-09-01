//
//  RemoteUnlockManager.swift
//  MacDeck (macOS Host)
//
//  Backs the "Allow Unlock from Phone" setting:
//   - Watches com.apple.screenIsLocked / screenIsUnlocked so the app
//     knows the Mac's lock state (published as `isLocked`).
//   - Stores the Mac account password in the macOS Keychain — never in
//     UserDefaults, never sent anywhere over the network.
//   - On a verified unlock trigger (a tap on the "Unlock Mac" tile),
//     types the stored password into the lock screen with CGEvent and
//     presses Return.
//
//  NOTE: typing into the lock screen requires Accessibility permission
//  (same permission already required for media keys / shortcuts in
//  SystemActionEngine). If it hasn't been granted, attemptUnlock()
//  fails and posts .phoneDeckNeedsAccessibility so the UI banner shows.
//

import AppKit
import Combine
import Security

@MainActor
final class RemoteUnlockManager: NSObject, ObservableObject {

    static let shared = RemoteUnlockManager()

    /// True while the Mac's screen is locked. DeckNetworkManager observes
    /// this to switch the phone to/from the locked-page layout.
    @Published private(set) var isLocked: Bool = false

    /// True once the user has enabled "Allow Unlock from Phone" and saved
    /// a password. False if they never turned it on, or turned it off.
    @Published private(set) var isEnabled: Bool

    private static let keychainService = "com.macdeck.remoteUnlockPassword"
    private static let legacyKeychainService = "com.phonedeck.remoteUnlockPassword"
    private static let enabledDefaultsKey = "macdeck.remoteUnlockEnabled"
    private static let legacyEnabledDefaultsKey = "phonedeck.remoteUnlockEnabled"

    private override init() {
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) != nil {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.legacyEnabledDefaultsKey)
        }
        super.init()

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            self, selector: #selector(handleScreenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil
        )
        dnc.addObserver(
            self, selector: #selector(handleScreenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Lock state

    @objc nonisolated private func handleScreenLocked(_ note: Notification) {
        Task { @MainActor in self.isLocked = true }
    }

    @objc nonisolated private func handleScreenUnlocked(_ note: Notification) {
        Task { @MainActor in self.isLocked = false }
    }

    // MARK: - Enable / disable

    /// Called after the user enters their Mac password in the settings
    /// sheet. Saves it to Keychain and flips the setting on.
    func enable(password: String) throws {
        try savePasswordToKeychain(password)
        isEnabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
    }

    /// Turns the setting off and removes the stored password entirely.
    func disable() {
        deletePasswordFromKeychain()
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
        UserDefaults.standard.set(false, forKey: Self.legacyEnabledDefaultsKey)
    }

    /// Verifies the provided password matches the one stored in Keychain.
    /// Returns false if no password is stored.
    func verify(password: String) -> Bool {
        guard let stored = retrievePasswordFromKeychain() else { return false }
        return stored == password
    }

    // MARK: - Unlock

    /// Guards against a double-tap on the phone's unlock tile (or an
    /// overlapping TRIGGER_SLOT) triggering two overlapping unlock attempts —
    /// typing the password twice, or pressing Return twice in a row.
    private var isUnlocking = false

    /// Called when the "Unlock Mac" tile is triggered from the phone.
    /// Returns false (and does nothing destructive) if the feature isn't
    /// enabled, no password is stored, Accessibility isn't granted, or an
    /// unlock is already in progress.
    @discardableResult
    func attemptUnlock() async -> Bool {
        guard !isUnlocking else {
            NSLog("MacDeck: unlock already in progress, ignoring duplicate request")
            return false
        }
        guard isEnabled else {
            NSLog("MacDeck: unlock requested but 'Allow Unlock from Phone' is off")
            return false
        }
        guard let password = retrievePasswordFromKeychain(), !password.isEmpty else {
            NSLog("MacDeck: unlock requested but no password is stored in Keychain")
            return false
        }
        guard SystemActionEngine.shared.refreshAccessibilityPermission(prompt: false) else {
            NSLog("MacDeck: unlock requested but Accessibility permission is missing")
            NotificationCenter.default.post(name: .phoneDeckNeedsAccessibility, object: nil)
            return false
        }

        isUnlocking = true
        defer { isUnlocking = false }

        let isAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0

        if isAsleep {
            // Wake up the screen explicitly using caffeinate, then give it
            // time to actually turn on before we start typing. Posting
            // keystrokes does NOT wake a sleeping display, and pressing
            // Return here (as an earlier version did) submits a blank
            // password on the still-fresh lock screen — an avoidable
            // failed attempt every single unlock.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            task.arguments = ["-u", "-t", "2"]
            try? task.run()
            // Task.sleep suspends without blocking the main thread — unlike
            // usleep(), which froze the entire app (no UI updates, no other
            // WebSocket messages processed) for over a second on every
            // remote unlock while the display was waking.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }

        // Type password and submit
        typeString(password)
        try? await Task.sleep(nanoseconds: 100_000_000) // let the password field settle before submitting
        await pressReturn()

        return true
    }

    // MARK: - Keychain

    private func savePasswordToKeychain(_ password: String) throws {
        let account = NSUserName()
        guard let data = password.data(using: .utf8) else {
            throw NSError(domain: "RemoteUnlockManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid password encoding."
            ])
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account
        ]

        // Clear legacy item if present
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyKeychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(legacyQuery as CFDictionary)

        // Clear existing item first so re-enabling overwrites cleanly
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data

        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        }

        guard status == errSecSuccess else {
            let errorMsg = (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain status \(status)"
            NSLog("MacDeck: Failed to save password to Keychain (status \(status): \(errorMsg))")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Failed to save password to Keychain (\(errorMsg))"
            ])
        }
    }

    private func retrievePasswordFromKeychain() -> String? {
        let account = NSUserName()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) {
            return password
        }

        // Fallback for legacy service key
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var legacyResult: AnyObject?
        let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)
        if legacyStatus == errSecSuccess, let data = legacyResult as? Data, let password = String(data: data, encoding: .utf8) {
            return password
        }

        return nil
    }

    @discardableResult
    private func deletePasswordFromKeychain() -> Bool {
        let account = NSUserName()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)

        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyKeychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(legacyQuery as CFDictionary)

        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Typing (CGEvent, same session-tap technique already used

    // elsewhere in SystemActionEngine for media keys / shortcuts)

    /// Types an arbitrary Unicode string via a single synthetic keyboard
    /// event rather than mapping each character to a virtual key code —
    /// this handles any password content correctly regardless of layout.
    private func typeString(_ string: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let utf16Chars = Array(string.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }

        keyDown.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
        keyDown.post(tap: .cgSessionEventTap)

        keyUp.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
        keyUp.post(tap: .cgSessionEventTap)
    }

    private func pressReturn() async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true), // Return
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else { return }
        keyDown.post(tap: .cgSessionEventTap)
        try? await Task.sleep(nanoseconds: 10_000_000)
        keyUp.post(tap: .cgSessionEventTap)
    }
}
