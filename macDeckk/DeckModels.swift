//
//  DeckModels.swift
//  MacDeck (macOS Host)
//
//  Core data models + the JSON wire protocol shared between the Mac host
//  and the phone client over the WebSocket connection.
//

import Foundation

// MARK: - Tile / Page models

enum TileType: Codable, Hashable {
    case app(bundleIdentifier: String, name: String)
    case systemControl(action: SystemControlAction)
    case browserControl(action: BrowserControlAction)
    case website(url: String, name: String)
    case shortcut(name: String)
    case obsControl(action: OBSControlAction)
    case discordControl(action: DiscordControlAction)

    // Custom coding so this enum serializes as a flat, phone-friendly JSON
    // object instead of Swift's default nested single-key-dictionary form.
    private enum CodingKeys: String, CodingKey {
        case type, bundleIdentifier, name, action, url
    }

    private enum Kind: String, Codable {
        case app, systemControl, browserControl, website, shortcut, obsControl, discordControl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .app:
            self = .app(
                bundleIdentifier: try c.decode(String.self, forKey: .bundleIdentifier),
                name: try c.decode(String.self, forKey: .name)
            )
        case .systemControl:
            self = .systemControl(action: try c.decode(SystemControlAction.self, forKey: .action))
        case .browserControl:
            self = .browserControl(action: try c.decode(BrowserControlAction.self, forKey: .action))
        case .website:
            self = .website(
                url: try c.decode(String.self, forKey: .url),
                name: try c.decode(String.self, forKey: .name)
            )
        case .shortcut:
            self = .shortcut(name: try c.decode(String.self, forKey: .name))
        case .obsControl:
            self = .obsControl(action: try c.decode(OBSControlAction.self, forKey: .action))
        case .discordControl:
            self = .discordControl(action: try c.decode(DiscordControlAction.self, forKey: .action))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let bundleIdentifier, let name):
            try c.encode(Kind.app, forKey: .type)
            try c.encode(bundleIdentifier, forKey: .bundleIdentifier)
            try c.encode(name, forKey: .name)
        case .systemControl(let action):
            try c.encode(Kind.systemControl, forKey: .type)
            try c.encode(action, forKey: .action)
        case .browserControl(let action):
            try c.encode(Kind.browserControl, forKey: .type)
            try c.encode(action, forKey: .action)
        case .website(let url, let name):
            try c.encode(Kind.website, forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(name, forKey: .name)
        case .shortcut(let name):
            try c.encode(Kind.shortcut, forKey: .type)
            try c.encode(name, forKey: .name)
        case .obsControl(let action):
            try c.encode(Kind.obsControl, forKey: .type)
            try c.encode(action, forKey: .action)
        case .discordControl(let action):
            try c.encode(Kind.discordControl, forKey: .type)
            try c.encode(action, forKey: .action)
        }
    }

    /// Label shown on the tile when no custom label is set.
    var defaultLabel: String {
        switch self {
        case .app(_, let name): return name
        case .website(_, let name): return name
        case .shortcut(let name): return name
        case .systemControl(let action): return action.displayName
        case .browserControl(let action): return action.displayName
        case .obsControl(let action): return action.displayName
        case .discordControl(let action): return action.displayName
        }
    }
}

/// Actions for the auto-generated OBS control page. Sent to OBS over the
/// built-in obs-websocket server (OBS 28+, Tools ▸ WebSocket Server
/// Settings) — see OBSControlManager.
enum OBSControlAction: Codable, Hashable {
    case switchScene(name: String)
    case startRecording, stopRecording
    case toggleRecording
    case toggleStreaming
    case toggleReplayBuffer
    case toggleMicMute

    private enum CodingKeys: String, CodingKey { case kind, name }
    private enum Kind: String, Codable { case switchScene, startRecording, stopRecording, toggleRecording, toggleStreaming, toggleReplayBuffer, toggleMicMute }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .switchScene: self = .switchScene(name: try c.decode(String.self, forKey: .name))
        case .startRecording: self = .startRecording
        case .stopRecording: self = .stopRecording
        case .toggleRecording: self = .toggleRecording
        case .toggleStreaming: self = .toggleStreaming
        case .toggleReplayBuffer: self = .toggleReplayBuffer
        case .toggleMicMute: self = .toggleMicMute
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .switchScene(let name):
            try c.encode(Kind.switchScene, forKey: .kind)
            try c.encode(name, forKey: .name)
        case .startRecording: try c.encode(Kind.startRecording, forKey: .kind)
        case .stopRecording: try c.encode(Kind.stopRecording, forKey: .kind)
        case .toggleRecording: try c.encode(Kind.toggleRecording, forKey: .kind)
        case .toggleStreaming: try c.encode(Kind.toggleStreaming, forKey: .kind)
        case .toggleReplayBuffer: try c.encode(Kind.toggleReplayBuffer, forKey: .kind)
        case .toggleMicMute: try c.encode(Kind.toggleMicMute, forKey: .kind)
        }
    }

    var displayName: String {
        switch self {
        case .switchScene(let name): return name
        case .startRecording: return "Start Recording"
        case .stopRecording: return "Stop Recording"
        case .toggleRecording: return "Record"
        case .toggleStreaming: return "Stream"
        case .toggleReplayBuffer: return "Replay Buffer"
        case .toggleMicMute: return "Mic"
        }
    }

    var defaultSystemImageName: String {
        switch self {
        case .switchScene: return "square.stack.3d.up"
        case .toggleRecording, .startRecording, .stopRecording: return "record.circle"
        case .toggleStreaming: return "dot.radiowaves.left.and.right"
        case .toggleReplayBuffer: return "gobackward"
        case .toggleMicMute: return "mic"
        }
    }
}

/// Pinned bot channels and the local desktop client’s call controls.
enum DiscordControlAction: Codable, Hashable {
    case openChannel(guildID: String, channelID: String, isDM: Bool)

    case call(DiscordCallButton)

    private enum CodingKeys: String, CodingKey { case kind, guildID, channelID, isDM, button }
    private enum Kind: String, Codable { case openChannel, call }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(Kind.self, forKey: .kind) == .call {
            self = .call(try c.decode(DiscordCallButton.self, forKey: .button))
            return
        }
        self = .openChannel(
            guildID: try c.decode(String.self, forKey: .guildID),
            channelID: try c.decode(String.self, forKey: .channelID),
            isDM: try c.decodeIfPresent(Bool.self, forKey: .isDM) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if case .call(let button) = self {
            try c.encode(Kind.call, forKey: .kind)
            try c.encode(button, forKey: .button)
            return
        }
        guard case .openChannel(let guildID, let channelID, let isDM) = self else { return }
        try c.encode(Kind.openChannel, forKey: .kind)
        try c.encode(guildID, forKey: .guildID)
        try c.encode(channelID, forKey: .channelID)
        try c.encode(isDM, forKey: .isDM)
    }

    var displayName: String {
        if case .call(let button) = self { return button.label }
        return "Open"
    }
    var defaultSystemImageName: String {
        if case .call(let button) = self { return button.symbol }
        guard case .openChannel(_, _, let isDM) = self else { return "number" }
        return isDM ? "person.circle" : "number"
    }
}

enum BrowserControlAction: String, Codable, CaseIterable {
    case switchTab1, switchTab2, switchTab3, switchTab4, switchTab5
    case back, forward, refresh, newTab, closeTab
    
    var displayName: String {
        switch self {
        case .switchTab1: return "Tab 1"
        case .switchTab2: return "Tab 2"
        case .switchTab3: return "Tab 3"
        case .switchTab4: return "Tab 4"
        case .switchTab5: return "Tab 5"
        case .back: return "Back"
        case .forward: return "Forward"
        case .refresh: return "Refresh"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        }
    }
}

enum SystemControlAction: String, Codable, CaseIterable {
    case brightnessUp, brightnessDown
    case kbBrightnessUp, kbBrightnessDown
    case playPause, nextTrack, previousTrack
    case mute, volumeUp, volumeDown
    case screenshot, screenRecord
    case keepAwake, quitFrontmostApp, lockScreen, sleepMac
    case desktop, missionControl, emptyTrash
    case unlockMac
    case dnd

    var displayName: String {
        switch self {
        case .brightnessUp: return "Bright"
        case .brightnessDown: return "Dim"
        case .kbBrightnessUp: return "KB Bright"
        case .kbBrightnessDown: return "KB Dim"
        case .playPause: return "Play"
        case .nextTrack: return "Next"
        case .previousTrack: return "Previous"
        case .mute: return "Mute"
        case .volumeUp: return "Vol +"
        case .volumeDown: return "Vol -"
        case .screenshot: return "Screenshot"
        case .screenRecord: return "Record"
        case .keepAwake: return "Caffeine"
        case .quitFrontmostApp: return "Quit App"
        case .lockScreen: return "Lock"
        case .sleepMac: return "Sleep Mac"
        case .desktop: return "Desktop"
        case .missionControl: return "Mission Ctrl"
        case .emptyTrash: return "Empty Trash"
        case .unlockMac: return "Unlock Mac"
        case .dnd: return "Do Not Disturb"
        }
    }
    var defaultSystemImageName: String {
        switch self {
        case .brightnessUp: return "sun.max"
        case .brightnessDown: return "sun.min"
        case .kbBrightnessUp: return "light.max"
        case .kbBrightnessDown: return "light.min"
        case .playPause: return "playpause"
        case .nextTrack: return "forward.end"
        case .previousTrack: return "backward.end"
        case .mute: return "speaker.slash"
        case .volumeUp: return "speaker.wave.3"
        case .volumeDown: return "speaker.wave.1"
        case .screenshot: return "camera.viewfinder"
        case .screenRecord: return "record.circle"
        case .keepAwake: return "cup.and.saucer"
        case .quitFrontmostApp: return "xmark.app"
        case .lockScreen: return "lock.laptopcomputer" // Mac specific
        case .sleepMac: return "moon.zzz"
        case .desktop: return "macwindow"
        case .missionControl: return "macwindow.on.rectangle" // Mac specific
        case .emptyTrash: return "trash"
        case .unlockMac: return "lock.open.laptopcomputer"
        case .dnd: return "moon.fill"
        }
    }

    var macKeyBadge: String {
        switch self {
        case .brightnessDown: return "F1"
        case .brightnessUp: return "F2"
        case .missionControl: return "F3"
        case .kbBrightnessDown: return "F5"
        case .kbBrightnessUp: return "F6"
        case .previousTrack: return "F7"
        case .playPause: return "F8"
        case .nextTrack: return "F9"
        case .mute: return "F10"
        case .volumeDown: return "F11"
        case .volumeUp: return "F12"
        case .screenshot: return "⌘⇧4"
        case .screenRecord: return "⌘⇧5"
        case .lockScreen: return "⌃⌘Q"
        case .quitFrontmostApp: return "⌘Q"
        case .desktop: return "Fn F11"
        case .emptyTrash: return "⌘⇧⌥⌫"
        case .keepAwake: return "☕"
        case .sleepMac: return "☾"
        case .unlockMac: return "Touch ID"
        case .dnd: return "F6"
        }
    }
}

struct DeckTile: Identifiable, Codable, Hashable {
    var id = UUID()
    var slotIndex: Int // 0..<DeckPage.slotCount for the 2x5 grid
    var tileType: TileType
    var customLabel: String?
    var iconData: Data? // PNG payload, base64-encoded over the wire by Codable

    var label: String { customLabel ?? tileType.defaultLabel }
}

// MARK: - Drag payload (shared with PhoneFrameGridView for drop handling)
nonisolated struct DragTilePayload: Codable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable { case app, control, website, shortcut, existingTile }
    let kind: Kind
    let bundleID: String?
    let appName: String?
    let control: SystemControlAction?
    let url: String?
    let websiteName: String?
    let shortcutName: String?
    var sourceSlot: Int? = nil
}

struct DeckPage: Identifiable, Codable, Hashable {
    static let slotCount = 20

    var id = UUID()
    var name: String
    var pageNumber: Int
    var tiles: [DeckTile?] = Array(repeating: nil, count: slotCount)

    /// Bundle identifiers that auto-switch the phone to this page when one
    /// of them becomes the frontmost app (e.g. a per-app "profile" page).
    /// Empty means the page is never auto-triggered. See AppFrontmostMonitor
    /// and DeckNetworkManager.handleFrontmostAppChange.
    var triggerBundleIDs: [String] = []

    init(id: UUID = UUID(), name: String, pageNumber: Int, tiles: [DeckTile?] = Array(repeating: nil, count: DeckPage.slotCount), triggerBundleIDs: [String] = []) {
        self.id = id
        self.name = name
        self.pageNumber = pageNumber
        self.tiles = tiles
        self.triggerBundleIDs = triggerBundleIDs
    }

    // Custom Codable so a `triggerBundleIDs` key missing from an
    // already-saved pages.json (written before this field existed) decodes
    // as `[]` instead of failing the whole array's decode — the auto-
    // synthesized Codable would throw on the first old page it saw, and
    // PageStore's `try?` around that decode would silently discard every
    // saved page and reset to a blank default. Same reasoning applies to
    // `id`/`tiles`, which already existed but are given defaults here too
    // so this stays robust to future trimmed-down JSON.
    private enum CodingKeys: String, CodingKey { case id, name, pageNumber, tiles, triggerBundleIDs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        pageNumber = try c.decode(Int.self, forKey: .pageNumber)
        tiles = try c.decodeIfPresent([DeckTile?].self, forKey: .tiles) ?? Array(repeating: nil, count: Self.slotCount)
        triggerBundleIDs = try c.decodeIfPresent([String].self, forKey: .triggerBundleIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(pageNumber, forKey: .pageNumber)
        try c.encode(tiles, forKey: .tiles)
        try c.encode(triggerBundleIDs, forKey: .triggerBundleIDs)
    }
}

// MARK: - Wire protocol (Mac <-> Phone JSON payloads)

/// Messages the Mac host sends down to the phone client.
enum ServerMessage: Codable {
    case pageSync([DeckPage])
    case switchToPage(pageID: UUID)
    case pong
    case error(message: String)
    case pairingPending
    case pairingApproved
    case pairingDenied
    case versionMismatch(requiredVersion: Int)
    case lockStateChanged(isLocked: Bool)

    private enum CodingKeys: String, CodingKey { case type, page, pages, pageID, message, requiredVersion, isLocked }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try c.decode(String.self, forKey: .type)
        let type = rawType.uppercased()

        switch type {
        case "PAGE_SYNC":
            // Support both legacy key ("page") and newer ("pages").
            if let p = try? c.decode([DeckPage].self, forKey: .page) {
                self = .pageSync(p)
            } else {
                self = .pageSync(try c.decode([DeckPage].self, forKey: .pages))
            }
        case "SWITCH_TO_PAGE":
            self = .switchToPage(pageID: try c.decode(UUID.self, forKey: .pageID))
        case "PONG":
            self = .pong
        case "ERROR":
            self = .error(message: try c.decode(String.self, forKey: .message))
        case "PAIRING_PENDING":
            self = .pairingPending
        case "PAIRING_APPROVED":
            self = .pairingApproved
        case "PAIRING_DENIED":
            self = .pairingDenied
        case "VERSION_MISMATCH":
            self = .versionMismatch(requiredVersion: try c.decode(Int.self, forKey: .requiredVersion))
        case "LOCK_STATE_CHANGED":
            self = .lockStateChanged(isLocked: try c.decode(Bool.self, forKey: .isLocked))
        default:
            // Backwards-compatibility for older lowercase encodings
            switch rawType {
            case "pageSync":
                if let p = try? c.decode([DeckPage].self, forKey: .page) {
                    self = .pageSync(p)
                } else {
                    self = .pageSync(try c.decode([DeckPage].self, forKey: .pages))
                }
            case "pong": self = .pong
            case "error": self = .error(message: try c.decode(String.self, forKey: .message))
            case "pairingPending": self = .pairingPending
            case "pairingApproved": self = .pairingApproved
            case "pairingDenied": self = .pairingDenied
            case "versionMismatch": self = .versionMismatch(requiredVersion: try c.decode(Int.self, forKey: .requiredVersion))
            case "lockStateChanged": self = .lockStateChanged(isLocked: try c.decode(Bool.self, forKey: .isLocked))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown server message type: \(rawType)")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pageSync(let pages):
            // Encode once, under "page" — the key the phone clients actually
            // read (non-optional field, no fallback). Writing an identical
            // second copy under "pages" was silently doubling the payload
            // size of every full sync, which includes every tile's base64
            // icon data. Decode still accepts either key for old servers.
            try c.encode("pageSync", forKey: .type)
            try c.encode(pages, forKey: .page)
        case .switchToPage(let pageID):
            try c.encode("switchToPage", forKey: .type)
            try c.encode(pageID, forKey: .pageID)
        case .pong:
            try c.encode("pong", forKey: .type)
        case .error(let message):
            try c.encode("error", forKey: .type)
            try c.encode(message, forKey: .message)
        case .pairingPending:
            try c.encode("pairingPending", forKey: .type)
        case .pairingApproved:
            try c.encode("pairingApproved", forKey: .type)
        case .pairingDenied:
            try c.encode("pairingDenied", forKey: .type)
        case .versionMismatch(let v):
            try c.encode("versionMismatch", forKey: .type)
            try c.encode(v, forKey: .requiredVersion)
        case .lockStateChanged(let isLocked):
            try c.encode("lockStateChanged", forKey: .type)
            try c.encode(isLocked, forKey: .isLocked)
        }
    }
}

/// Messages the phone client sends up to the Mac host.
enum ClientCommand: Codable {
    case triggerSlot(pageID: UUID, slotIndex: Int)
    case requestSync
    case ping
    case hello(clientID: String, deviceName: String, protocolVersion: Int, gridRows: Int)

    private enum CodingKeys: String, CodingKey { case command, pageID, slotIndex, clientID, deviceName, protocolVersion, gridRows }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let command = try c.decode(String.self, forKey: .command)
        switch command {
        case "TRIGGER_SLOT":
            self = .triggerSlot(
                pageID: try c.decode(UUID.self, forKey: .pageID),
                slotIndex: try c.decode(Int.self, forKey: .slotIndex)
            )
        case "REQUEST_SYNC":
            self = .requestSync
        case "PING":
            self = .ping
        case "HELLO":
            self = .hello(
                clientID: try c.decode(String.self, forKey: .clientID),
                deviceName: try c.decode(String.self, forKey: .deviceName),
                protocolVersion: try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1,
                gridRows: try c.decodeIfPresent(Int.self, forKey: .gridRows) ?? 2
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .command, in: c, debugDescription: "Unknown command: \(command)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .triggerSlot(let pageID, let slotIndex):
            try c.encode("TRIGGER_SLOT", forKey: .command)
            try c.encode(pageID, forKey: .pageID)
            try c.encode(slotIndex, forKey: .slotIndex)
        case .requestSync:
            try c.encode("REQUEST_SYNC", forKey: .command)
        case .ping:
            try c.encode("PING", forKey: .command)
        case let .hello(clientID, deviceName, protocolVersion, gridRows):
            try c.encode("HELLO", forKey: .command)
            try c.encode(clientID, forKey: .clientID)
            try c.encode(deviceName, forKey: .deviceName)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(gridRows, forKey: .gridRows)
        }
    }
}
