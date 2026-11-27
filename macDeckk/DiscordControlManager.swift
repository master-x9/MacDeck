//
//  DiscordControlManager.swift
//  MacDeck (macOS Host)
//
//  IMPORTANT — read before wiring up: this connects to Discord as a BOT
//  that you create yourself (Discord Developer Portal → New Application →
//  Bot → copy token, enable "Message Content Intent" under Privileged
//  Gateway Intents, then invite the bot to your own server(s)). This is
//  Discord's standard, ToS-compliant way for a local tool to integrate.
//
//  MacDeck deliberately does NOT use your personal Discord account token
//  to log in "as you" (a.k.a. self-botting). Discord's Terms of Service
//  prohibit automating a real user account that way, and doing so risks
//  that account being banned — so this file only ever talks to Discord
//  using a bot token, and is upfront about what that means it can't do:
//
//   • It cannot list or read YOUR personal DM list. Discord's Bot API has
//     no endpoint for another user's DMs — only DM channels the bot
//     itself has exchanged messages in. "DMs" below means the latter.
//   • It cannot detect "you were @mentioned" — only "this bot was
//     @mentioned", or "a new message arrived in a channel you pinned".
//     The Discord page's "surfaces on new activity" behavior is built on
//     that second, honest signal.
//   • Desktop call controls are provided separately by DiscordCalls.

import Foundation
import AppKit
import Combine
import Security

struct DiscordChannelRef: Codable, Hashable, Identifiable {
    var id: String { channelID }
    let guildID: String?      // nil for a DM channel
    let guildName: String?
    let guildIconHash: String?
    let channelID: String
    let channelName: String
    let isDM: Bool
}

struct DiscordGuildInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let iconHash: String?
    var textChannels: [DiscordChannelRef] = []
}

/// Fetches + caches guild icons from Discord's public CDN (no auth
/// required for CDN asset URLs). Mirrors the WebsiteIconLoader pattern
/// used for website tiles elsewhere in the app, at the same 128×128
/// resolution every other tile icon in MacDeck uses.
@MainActor
enum DiscordIconCache {
    private static var cache: [String: Data] = [:]
    private static var inFlight: Set<String> = []

    static func cachedIconData(guildID: String, iconHash: String) -> Data? {
        cache["\(guildID)_\(iconHash)"]
    }

    static func loadIcon(guildID: String, iconHash: String, completion: @escaping (Data?) -> Void) {
        let key = "\(guildID)_\(iconHash)"
        if let cached = cache[key] { completion(cached); return }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        guard let url = URL(string: "https://cdn.discordapp.com/icons/\(guildID)/\(iconHash).png?size=256") else {
            inFlight.remove(key)
            completion(nil)
            return
        }
        Task.detached(priority: .utility) {
            let result: Data? = await {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data) else { return nil }
                return image.pngData(size: CGSize(width: 128, height: 128))
            }()
            await MainActor.run {
                DiscordIconCache.inFlight.remove(key)
                if let result { DiscordIconCache.cache[key] = result }
                completion(result)
            }
        }
    }
}

@MainActor
final class DiscordControlManager: NSObject, ObservableObject {
    static let shared = DiscordControlManager()

    /// Discord desktop app's bundle identifier.
    static let discordBundleID = "com.hnc.Discord"
    static let discordPageID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    /// Every guild the bot is in, with its text channels — feeds the
    /// picker in Settings. Only guilds the bot itself has been invited to.
    @Published private(set) var availableGuilds: [DiscordGuildInfo] = []
    /// DM channels the bot has actually had opened with it — NOT the
    /// human user's own DM list (see the file header comment).
    @Published private(set) var availableDMChannels: [DiscordChannelRef] = []

    /// The channels the user has chosen to pin as tiles. Persisted
    /// locally (channel/guild names + IDs only — nothing sensitive).
    @Published private(set) var pinnedChannels: [DiscordChannelRef] = [] {
        didSet { persistPinned(); rebuildPage() }
    }

    /// Dynamically-generated page shown on the phone. `nil` while
    /// disconnected or nothing is pinned yet.
    @Published private(set) var discordPage: DeckPage?

    // MARK: - Settings

    private static let keychainService = "com.macdeck.discordBotToken"
    private static let pinnedDefaultsKey = "macdeck.discord.pinnedChannels"

    func hasToken() -> Bool { retrieveToken() != nil }

    /// Updates the stored bot token and reconnects with it.
    func setToken(_ token: String?) {
        if let token, !token.isEmpty {
            saveToken(token)
        } else {
            deleteToken()
        }
        disconnect()
        if let token, !token.isEmpty, AppFrontmostMonitor.shared.isRunning(Self.discordBundleID) {
            _ = token
            connect()
        }
    }

    func setPinnedChannels(_ channels: [DiscordChannelRef]) {
        pinnedChannels = Array(channels.prefix(DeckPage.slotCount))
    }

    // MARK: - Private state

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeatTimer: Timer?
    private var lastSequence: Int?
    private var botUserID: String?
    private var frontmostCancellable: AnyCancellable?
    private var reconnectWorkItem: DispatchWorkItem?
    /// Channel ID that most recently had activity (bot mention, or a new
    /// message in a pinned channel) — pinned to slot 0 of the page.
    private var mostRecentActivityChannelID: String?

    private override init() {
        super.init()
        loadPinned()
        // Only connect while Discord itself is running — same reasoning
        // as OBSControlManager: no idle background socket when the app
        // the feature is about isn't even open.
        frontmostCancellable = AppFrontmostMonitor.shared.$runningBundleIDs
            .map { $0.contains(Self.discordBundleID) }
            .removeDuplicates()
            .sink { [weak self] running in
                guard let self else { return }
                if running, self.hasToken() {
                    self.connect()
                } else if !running {
                    self.disconnect()
                }
            }
        if AppFrontmostMonitor.shared.isRunning(Self.discordBundleID), hasToken() {
            connect()
        }
    }

    // MARK: - Connection

    private func connect() {
        guard webSocketTask == nil else { return }
        guard let url = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json") else { return }
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.webSocketTask = task
        lastSequence = nil
        task.resume()
        receiveLoop()
    }

    private func disconnect() {
        reconnectWorkItem?.cancel()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session = nil
        isConnected = false
        discordPage = nil
    }

    private func scheduleReconnect() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        webSocketTask = nil
        session = nil
        isConnected = false
        guard hasToken(), AppFrontmostMonitor.shared.isRunning(Self.discordBundleID) else { return }
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func receiveLoop() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, let currentTask = self.webSocketTask else { return }
                switch result {
                case .failure:
                    self.scheduleReconnect()
                    return
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handleMessage(text) }
                    @unknown default: break
                    }
                }
                if self.webSocketTask === currentTask {
                    self.receiveLoop()
                }
            }
        }
    }

    private func sendRaw(_ dict: [String: Any]) {
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { NSLog("MacDeck[Discord]: send failed: \(error)") }
        }
    }

    // MARK: - Gateway protocol

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? Int else { return }

        if let seq = obj["s"] as? Int { lastSequence = seq }

        switch op {
        case 10: // Hello
            if let d = obj["d"] as? [String: Any], let interval = d["heartbeat_interval"] as? Double {
                startHeartbeat(intervalMs: interval)
                identify()
            }
        case 0: // Dispatch
            if let t = obj["t"] as? String, let d = obj["d"] as? [String: Any] {
                handleDispatch(t, d)
            }
        case 7: // Reconnect requested
            scheduleReconnect()
        case 9: // Invalid session
            scheduleReconnect()
        case 11: // Heartbeat ACK
            break
        default:
            break
        }
    }

    private func startHeartbeat(intervalMs: Double) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: intervalMs / 1000.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Discord's spec: heartbeat `d` is the last sequence number
                // seen, or JSON null if none yet. `self.lastSequence ?? NSNull()`
                // (rather than boxing the Int? straight into Any) avoids a
                // Foundation gotcha where JSONSerialization silently rejects
                // an Any that wraps a nil Optional instead of a real null.
                self.sendRaw(["op": 1, "d": self.lastSequence ?? NSNull()])
            }
        }
    }

    private func identify() {
        guard let token = retrieveToken() else {
            lastError = "No Discord bot token configured."
            disconnect()
            return
        }
        // GUILDS | GUILD_MESSAGES | MESSAGE_CONTENT | DIRECT_MESSAGES.
        // MESSAGE_CONTENT is a privileged intent — must be turned on for
        // this bot in the Developer Portal or Discord will close the
        // connection (code 4014) right after this.
        let intents = 1 | 512 | 32768 | 4096
        sendRaw([
            "op": 2,
            "d": [
                "token": token,
                "intents": intents,
                "properties": ["os": "macos", "browser": "MacDeck", "device": "MacDeck"],
            ],
        ])
    }

    private func handleDispatch(_ type: String, _ d: [String: Any]) {
        switch type {
        case "READY":
            isConnected = true
            lastError = nil
            botUserID = (d["user"] as? [String: Any])?["id"] as? String
            availableGuilds = []
        case "GUILD_CREATE":
            handleGuildCreate(d)
        case "GUILD_DELETE":
            if let id = d["id"] as? String {
                availableGuilds.removeAll { $0.id == id }
            }
        case "CHANNEL_CREATE":
            handleDMChannelCreate(d)
        case "MESSAGE_CREATE":
            handleMessageCreate(d)
        default:
            break
        }
    }

    private func handleGuildCreate(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return }
        let iconHash = d["icon"] as? String
        let channelsRaw = (d["channels"] as? [[String: Any]]) ?? []
        let textChannels: [DiscordChannelRef] = channelsRaw.compactMap { ch in
            guard let type = ch["type"] as? Int, type == 0, // GUILD_TEXT
                  let channelID = ch["id"] as? String,
                  let channelName = ch["name"] as? String else { return nil }
            return DiscordChannelRef(guildID: id, guildName: name, guildIconHash: iconHash, channelID: channelID, channelName: channelName, isDM: false)
        }
        var info = DiscordGuildInfo(id: id, name: name, iconHash: iconHash, textChannels: textChannels)
        info.textChannels.sort { $0.channelName < $1.channelName }
        availableGuilds.removeAll { $0.id == id }
        availableGuilds.append(info)
        availableGuilds.sort { $0.name < $1.name }
    }

    private func handleDMChannelCreate(_ d: [String: Any]) {
        guard let type = d["type"] as? Int, type == 1, // DM
              let channelID = d["id"] as? String else { return }
        let recipients = (d["recipients"] as? [[String: Any]]) ?? []
        let name = recipients.first?["username"] as? String ?? "Direct Message"
        let ref = DiscordChannelRef(guildID: nil, guildName: nil, guildIconHash: nil, channelID: channelID, channelName: name, isDM: true)
        if !availableDMChannels.contains(where: { $0.channelID == channelID }) {
            availableDMChannels.append(ref)
        }
    }

    private func handleMessageCreate(_ d: [String: Any]) {
        guard let channelID = d["channel_id"] as? String else { return }
        guard pinnedChannels.contains(where: { $0.channelID == channelID }) else { return }

        // Authoring bot's own messages don't count as "activity" worth
        // surfacing (avoids the tile jumping to slot 0 from its own echo
        // in a channel it's active in).
        let authorID = (d["author"] as? [String: Any])?["id"] as? String
        if authorID != nil, authorID == botUserID { return }

        mostRecentActivityChannelID = channelID
        rebuildPage()
    }

    // MARK: - Actions

    func execute(_ action: DiscordControlAction) {
        switch action {
        case .sidebar(let key):
            DiscordCalls.shared.pressSidebar(key)
        case .call(let button):
            DiscordCalls.shared.press(button)
        case .openChannel(let guildID, let channelID, _):
            // Opening the channel is itself an acknowledgment — clear the
            // "new activity" highlight for it.
            if mostRecentActivityChannelID == channelID {
                mostRecentActivityChannelID = nil
                rebuildPage()
            }
            let path = guildID.isEmpty ? "@me/\(channelID)" : "\(guildID)/\(channelID)"
            if let url = URL(string: "discord://discord.com/channels/\(path)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Page generation

    private func rebuildPage() {
        guard isConnected, !pinnedChannels.isEmpty else { discordPage = nil; return }

        // The channel with the most recent activity always leads.
        var ordered = pinnedChannels
        if let activeID = mostRecentActivityChannelID,
           let idx = ordered.firstIndex(where: { $0.channelID == activeID }), idx != 0 {
            let item = ordered.remove(at: idx)
            ordered.insert(item, at: 0)
        }

        var tiles: [DeckTile?] = Array(repeating: nil, count: DeckPage.slotCount)
        for (index, channel) in ordered.prefix(DeckPage.slotCount).enumerated() {
            let isActive = channel.channelID == mostRecentActivityChannelID
            let label = channel.isDM ? channel.channelName : "#\(channel.channelName)"
            let fallbackSymbol = channel.isDM ? "person.circle.fill" : "number"
            let fallbackIcon = SFSymbolIconGenerator.generate(
                symbolName: fallbackSymbol,
                foreground: .white,
                background: isActive ? NSColor.systemRed : NSColor(calibratedRed: 0.345, green: 0.396, blue: 0.949, alpha: 1) // Discord blurple-ish
            )
            tiles[index] = DeckTile(
                slotIndex: index,
                tileType: .discordControl(action: .openChannel(guildID: channel.guildID ?? "", channelID: channel.channelID, isDM: channel.isDM)),
                customLabel: isActive ? "\(label) •" : label,
                iconData: fallbackIcon
            )

            // If the guild has a real icon, fetch and swap it in once
            // available — same "show a good default now, upgrade when the
            // async fetch lands" approach used for website favicons.
            if let guildID = channel.guildID, let hash = channel.guildIconHash {
                if let cached = DiscordIconCache.cachedIconData(guildID: guildID, iconHash: hash) {
                    tiles[index]?.iconData = cached
                } else {
                    DiscordIconCache.loadIcon(guildID: guildID, iconHash: hash) { [weak self] data in
                        guard let self, let data else { return }
                        guard let currentIdx = self.discordPage?.tiles.firstIndex(where: { tile in
                            if case .discordControl(.openChannel(_, let cid, _)) = tile?.tileType {
                                return cid == channel.channelID
                            }
                            return false
                        }) else { return }
                        self.discordPage?.tiles[currentIdx]?.iconData = data
                    }
                }
            }
        }

        discordPage = DeckPage(id: Self.discordPageID, name: "Discord", pageNumber: -3, tiles: tiles)
    }

    // MARK: - Persistence (pinned channel list — not sensitive)

    private func persistPinned() {
        guard let data = try? JSONEncoder().encode(pinnedChannels) else { return }
        UserDefaults.standard.set(data, forKey: Self.pinnedDefaultsKey)
    }

    private func loadPinned() {
        guard let data = UserDefaults.standard.data(forKey: Self.pinnedDefaultsKey),
              let decoded = try? JSONDecoder().decode([DiscordChannelRef].self, from: data) else { return }
        pinnedChannels = decoded
    }

    // MARK: - Keychain (bot token)

    private func saveToken(_ token: String) {
        let account = NSUserName()
        guard let data = token.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func retrieveToken() -> String? {
        let account = NSUserName()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteToken() {
        let account = NSUserName()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
