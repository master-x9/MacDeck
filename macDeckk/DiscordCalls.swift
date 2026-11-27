import AppKit
import ApplicationServices
import Combine
import OSLog

nonisolated enum DiscordCallButton: String, Codable, CaseIterable {
    case deafen, undeafen, toggleDeafen, share, stopShare, openDiscord
    case mute, unmute, cameraOn, cameraOff, disconnect, answer, decline, showCall, toggleMute

    var label: String {
        switch self {
        case .toggleDeafen: "Toggle Deafen"
        case .deafen: "Deafen"
        case .undeafen: "Undeafen"
        case .share: "Share Screen"
        case .stopShare: "Stop Sharing"
        case .openDiscord: "Discord"
        case .showCall: "Show Call"
        case .toggleMute: "Toggle Mute"
        case .mute: "Mute"
        case .unmute: "Unmute"
        case .cameraOn: "Camera On"
        case .cameraOff: "Camera Off"
        case .disconnect: "Disconnect"
        case .answer: "Answer"
        case .decline: "Decline"
        }
    }

    var symbol: String {
        switch self {
        case .deafen, .toggleDeafen: "headphones"
        case .undeafen: "speaker.slash.fill"
        case .share: "display"
        case .stopShare: "display.and.arrow.down"
        case .openDiscord: "bubble.left.and.bubble.right.fill"
        case .showCall: "phone.arrow.up.right"
        case .toggleMute: "mic.circle"
        case .mute: "mic"
        case .unmute: "mic.slash"
        case .cameraOn: "video.slash"
        case .cameraOff: "video"
        case .disconnect, .decline: "phone.down.fill"
        case .answer: "phone.fill"
        }
    }

    init?(accessibleName: String) {
        let name = accessibleName.split(whereSeparator: \.isNewline).first.map(String.init)?
            .components(separatedBy: " (").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "deafen", "deafen audio", "deafen yourself": self = .deafen
        case "undeafen", "undeafen audio", "undeafen yourself": self = .undeafen
        case "share screen", "share your screen", "screen share", "start screen share": self = .share
        case "stop streaming", "stop sharing", "stop sharing your screen", "stop screen share": self = .stopShare
        case "mute", "mute microphone", "mute audio", "mute yourself": self = .mute
        case "unmute", "unmute microphone", "unmute audio", "unmute yourself": self = .unmute
        case "turn on camera", "turn camera on", "start video", "enable camera", "turn on video": self = .cameraOn
        case "turn off camera", "turn camera off", "stop video", "disable camera", "turn off video": self = .cameraOff
        case "disconnect", "leave call", "disconnect from voice", "disconnect call", "end call", "hang up", "leave voice channel": self = .disconnect
        case "answer", "join voice call", "accept voice call", "accept video call", "accept incoming call", "accept", "accept call", "answer call", "join call": self = .answer
        case "decline", "decline call": self = .decline
        default: return nil
        }
    }
}

private nonisolated struct DiscordDestination: Equatable {
    let key: String
    let name: String
    let direct: Bool
    let unread: Bool
    let count: String?

    init?(name label: String, identifier: String, url: URL?, servers: Bool, role: String) {
        let id = identifier.lowercased()
        let path = url?.path ?? ""
        let dm = path.hasPrefix("/channels/@me/") || id.contains("private-channels-") || id.hasPrefix("guildsnav___dm-")
        let server = id.range(of: #"^guildsnav___[0-9]+$"#, options: .regularExpression) != nil ||
            (servers && ["AXRow", "AXTreeItem", "AXButton", "AXLink"].contains(role))
        guard dm || server, !label.isEmpty, !id.contains("folder"),
              label.range(of: #"(?i)\b(folder|direct messages|add a server|discover servers|download apps)\b"#, options: .regularExpression) == nil else { return nil }
        let pattern = #"(?i)\b([0-9]+\+?)\s+(?:unread\s+)?(?:mentions?|messages?|notifications?)\b"#
        let range = label.range(of: pattern, options: .regularExpression)
        count = range.map { String(label[$0].prefix { $0.isNumber || $0 == "+" }) }
        unread = count.map { $0 != "0" } ?? (dm && label.localizedCaseInsensitiveContains("unread"))
        let clean = label.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(?:^|,\s*)(?:unread|server|guild)(?:,|$)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ", •:-").union(.whitespacesAndNewlines))
        guard !clean.isEmpty else { return nil }
        name = clean
        direct = dm
        key = (dm ? "dm:" : "server:") + (!identifier.isEmpty ? identifier : !path.isEmpty ? path : clean)
    }
}

private nonisolated struct DiscordSnapshot: Equatable {
    var buttons = Set<DiscordCallButton>()
    var entries: [DiscordDestination] = []
    var avatar: URL?
    var active: Bool { !buttons.isDisjoint(with: [.disconnect, .cameraOn, .cameraOff, .answer, .share, .stopShare]) }
}

@MainActor
final class DiscordCalls: ObservableObject {
    static let shared = DiscordCalls()
    static let pageID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    @Published private(set) var page: DeckPage?
    enum Status: String {
        case checking = "Checking Discord…"
        case disabled = "Discord calls disabled"
        case waitingForApp = "Waiting for Discord"
        case needsAccessibility = "Allow Accessibility for Discord calls"
        case waitingForCall = "Waiting for Discord call controls"
        case active = "Discord call controls available"
    }
    @Published private(set) var status = Status.checking
    private let logger = Logger(subsystem: "com.jk.MacDeck", category: "DiscordCalls")
    private var previous: DiscordSnapshot?
    private var avatarTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "MacDeck.DiscordCalls")
    private var scanning = false
    private var lastScanSummary = ""
    var enabled = true

    private init() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard !scanning else { return }
        guard enabled else { update(DiscordSnapshot(), status: .disabled); return }
        guard let pid = Self.discordPID else { update(DiscordSnapshot(), status: .waitingForApp); return }
        guard AXIsProcessTrusted() else { update(DiscordSnapshot(), status: .needsAccessibility); return }
        scanning = true
        queue.async {
            var summary = ""
            var snapshot = DiscordSnapshot()
            _ = Self.controls(pid: pid, snapshot: &snapshot, summary: &summary)
            let found = snapshot
            let scanSummary = summary
            Task { @MainActor in
                self.scanning = false
                guard self.enabled, Self.discordPID == pid else { self.refresh(); return }
                if scanSummary != self.lastScanSummary {
                    self.lastScanSummary = scanSummary
                    self.logger.info("Discord accessibility scan: \(scanSummary, privacy: .public)")
                }
                self.update(found, status: found.active ? .active : .waitingForCall)
            }
        }
    }

    static var discordPID: pid_t? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: DiscordControlManager.discordBundleID)
        if let pid = apps.map(\.processIdentifier).first(where: { $0 > 0 }) { return pid }
        // Launch Services can report -1 for Discord's versioned updater bundle.
        // Match the window owner's executable to that bundle before inspecting it.
        let paths = Set(apps.compactMap { $0.executableURL?.resolvingSymlinksInPath().path })
        guard !paths.isEmpty,
              let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows where window[kCGWindowOwnerName as String] as? String == "Discord" {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid > 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if length > 0, paths.contains(URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path) { return pid }
        }
        return nil
    }

    private func update(_ snapshot: DiscordSnapshot, status message: Status) {
        guard previous != snapshot || status != message else { return }
        previous = snapshot
        status = message
        avatarTask?.cancel()
        guard message != .disabled else { page = nil; return }
        let found = snapshot.buttons
        let name = found.contains(.answer) ? "Incoming Discord Call" : snapshot.active ? "Discord Call" : "Discord"
        var result = DeckPage(id: Self.pageID, name: name, pageNumber: -4)
        let slots: [[DiscordCallButton]] = [[.unmute, .mute, .toggleMute], [.undeafen, .deafen, .toggleDeafen], [.answer, .disconnect, .openDiscord],
                                            [.cameraOff, .cameraOn], [.stopShare, .share]]
        for (slot, options) in slots.enumerated() {
            guard let button = options.first(where: { found.contains($0) || $0 == .openDiscord }) else { continue }
            var icon = SFSymbolIconGenerator.generate(symbolName: button.symbol, foreground: .white, background: .systemIndigo)
            if button == .openDiscord, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DiscordControlManager.discordBundleID) {
                icon = NSWorkspace.shared.icon(forFile: url.path).pngData()
            }
            if button == .answer { icon = Self.badged(.init(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil), badge: "☎") }
            result.tiles[slot] = DeckTile(slotIndex: slot, tileType: .discordControl(action: .call(button)), customLabel: button.label, iconData: icon)
        }
        for (index, entry) in snapshot.entries.enumerated() {
            let symbol = entry.direct ? "person.crop.circle.fill" : "number"
            let icon = Self.badged(.init(systemSymbolName: symbol, accessibilityDescription: nil), badge: entry.unread ? (entry.count ?? "•") : nil)
            result.tiles[5 + index] = DeckTile(slotIndex: 5 + index, tileType: .discordControl(action: .sidebar(entry.key)), customLabel: entry.name, iconData: icon)
        }
        page = result
        if let url = snapshot.avatar?.appending(queryItems: [URLQueryItem(name: "size", value: "128")]), found.contains(.answer) {
            avatarTask = Task {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000,
                      let image = NSImage(data: data), !Task.isCancelled, previous == snapshot else { return }
                var updated = page
                updated?.tiles[2]?.iconData = Self.badged(image, badge: "☎")
                page = updated
            }
        }
    }

    private static func badged(_ image: NSImage?, badge: String?) -> Data? {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor.systemIndigo.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
            let artwork = image?.withSymbolConfiguration(.init(paletteColors: [.white])) ?? image
            artwork?.draw(in: rect.insetBy(dx: 12, dy: 12))
            if let badge {
                let title = badge as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 23), .foregroundColor: NSColor.white]
                let size = title.size(withAttributes: attrs)
                let box = NSRect(x: 124 - max(36, size.width + 14), y: 5, width: max(36, size.width + 14), height: 35)
                (badge == "☎" ? NSColor.systemGreen : .systemRed).setFill()
                NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
                if badge != "☎" {
                    let tail = NSBezierPath()
                    tail.move(to: NSPoint(x: box.minX + 8, y: 8))
                    tail.line(to: NSPoint(x: box.minX + 5, y: 0))
                    tail.line(to: NSPoint(x: box.minX + 19, y: 8))
                    tail.fill()
                }
                title.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attrs)
            }
            return true
        }.pngData()
    }

    func pressSidebar(_ key: String) {
        guard enabled, let pid = Self.discordPID else { return }
        queue.async {
            var snapshot = DiscordSnapshot(), summary = ""
            let result = Self.controls(pid: pid, snapshot: &snapshot, summary: &summary)
            if let node = result.links[key], AXUIElementPerformAction(node, kAXPressAction as CFString) != .success {
                AXUIElementSetAttributeValue(node, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    func press(_ button: DiscordCallButton) {
        guard enabled else { return }
        if button == .openDiscord {
            SystemActionEngine.shared.execute(.app(bundleIdentifier: DiscordControlManager.discordBundleID, name: "Discord"))
            return
        }
        guard let pid = Self.discordPID else { return }
        if [.showCall, .toggleMute, .toggleDeafen].contains(button) {
            guard AXIsProcessTrusted() else { return }
            let key: CGKeyCode = button == .showCall ? 9 : (button == .toggleDeafen ? 2 : 46)  // V, D, M
            let flags: CGEventFlags = button == .showCall ? [.maskCommand, .maskShift, .maskAlternate] : [.maskCommand, .maskShift]
            NSRunningApplication(processIdentifier: pid)?.activate()
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                event?.flags = flags
                event?.postToPid(pid)
            }
            return
        }
        queue.async {
            var summary = ""
            // Resolve again so a tap from a stale page cannot reverse a newer state.
            var snapshot = DiscordSnapshot()
            if let element = Self.controls(pid: pid, snapshot: &snapshot, summary: &summary).buttons[button] {
                AXUIElementPerformAction(element, kAXPressAction as CFString)
                Task { @MainActor in self.refresh() }
            }
        }
    }

    private nonisolated static func controls(pid: pid_t, snapshot: inout DiscordSnapshot, summary: inout String) -> (buttons: [DiscordCallButton: AXUIElement], links: [String: AXUIElement]) {
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, key as CFString, &value)
            return value
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var roots = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if roots.isEmpty { roots = [app] }
        var seen = Set<AXUIElement>()
        var nodes = Array(roots.reversed())
        var semanticButtons: [AXUIElement] = []
        var insideServers = Set<AXUIElement>()
        var entries: [DiscordDestination] = []
        var links: [String: AXUIElement] = [:]
        var found: [DiscordCallButton: AXUIElement] = [:]
        var buttonCount = 0
        var webAreas = 0
        var hints = Set<String>()
        let keys = [kAXRoleAttribute, kAXChildrenAttribute] as CFArray
        while seen.count < 16000, let node = nodes.popLast() ?? semanticButtons.popLast() {
            guard seen.insert(node).inserted else { continue }
            var values: CFArray?
            AXUIElementCopyMultipleAttributeValues(node, keys, [], &values)
            let attrs = values as? [Any] ?? []
            let role = attrs.first as? String ?? attribute(node, kAXRoleAttribute) as? String
            let children = attrs.last as? [AXUIElement] ?? attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            nodes.append(contentsOf: children.reversed())
            if let role {
                let navRoles = ["AXOutline", "AXTree", "AXNavigation", "AXLandmarkNavigation", "AXList", "AXGroup"]
                let itemRoles = ["AXRow", "AXTreeItem", "AXLink", "AXButton"]
                if navRoles.contains(role) || itemRoles.contains(role) {
                    let label = (attribute(node, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? attribute(node, kAXTitleAttribute) as? String ?? ""
                    let servers = insideServers.contains(node)
                    if servers || ["servers", "servers list"].contains(label.lowercased()) {
                        insideServers.formUnion(children)
                    }
                    if itemRoles.contains(role), let entry = DiscordDestination(name: label,
                        identifier: attribute(node, "AXDOMIdentifier") as? String ?? "",
                        url: attribute(node, kAXURLAttribute) as? URL, servers: servers, role: role), links[entry.key] == nil {
                        entries.append(entry)
                        links[entry.key] = node
                    }
                }
            }
            if role == "AXWebArea" {
                webAreas += 1
                // Chromium can expose buttons through semantic search even when a
                // virtualized subtree is absent from AXChildren.
                let query: [String: Any] = ["AXSearchKey": "AXButtonSearchKey", "AXDirection": "AXDirectionNext", "AXResultsLimit": 1024]
                var result: CFTypeRef?
                AXUIElementCopyParameterizedAttributeValue(node, "AXUIElementsForSearchPredicate" as CFString, query as CFDictionary, &result)
                semanticButtons.append(contentsOf: result as? [AXUIElement] ?? [])
            }
            let roles = ["AXButton", "AXCheckBox", "AXSwitch", "AXToggleButton", "AXPopUpButton", "AXMenuButton", "AXRadioButton", "AXLink", "AXGroup"]
            guard let role, roles.contains(role) else { continue }
            if role != "AXGroup" && role != "AXLink" { buttonCount += 1 }
            for key in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, "AXLabel"] {
                guard let label = attribute(node, key) as? String else { continue }
                // Record only predefined control terms, never window titles, people or chat text.
                for term in ["mute", "camera", "video", "disconnect", "voice connected", "leave call", "deafen"] where label.localizedCaseInsensitiveContains(term) {
                    hints.insert(term)
                }
                guard let button = DiscordCallButton(accessibleName: label),
                      attribute(node, kAXEnabledAttribute) as? Bool != false else { continue }
                if role == "AXGroup" || role == "AXLink" {
                    var actions: CFArray?
                    AXUIElementCopyActionNames(node, &actions)
                    guard (actions as? [String])?.contains(kAXPressAction) == true else { continue }
                }
                let checked = attribute(node, kAXValueAttribute) as? NSNumber
                let toggled: [DiscordCallButton: DiscordCallButton] = [.mute: .unmute, .deafen: .undeafen, .cameraOn: .cameraOff, .share: .stopShare]
                found[checked?.boolValue == true ? toggled[button] ?? button : button] = node
                break
            }
        }
        summary = "roots=\(roots.count) nodes=\(seen.count) webAreas=\(webAreas) buttons=\(buttonCount) terms=\(hints.sorted()) actions=\(found.keys.map(\.rawValue).sorted())"
        let unread = entries.filter(\.unread)
        snapshot.entries = Array((unread.isEmpty ? entries.filter { !$0.direct } : unread).prefix(5))
        let hasVoiceControls = found[.mute] != nil || found[.unmute] != nil
        if let answer = found[.answer], let decline = found[.decline] {
            snapshot.avatar = callerAvatar(answer, decline: decline)
            found.removeValue(forKey: .disconnect)
        } else {
            found.removeValue(forKey: .answer)
            found.removeValue(forKey: .decline)
            if found[.disconnect] == nil && !(hasVoiceControls && (found[.cameraOn] != nil || found[.cameraOff] != nil || hints.contains("voice connected"))) {
                found = found.filter { [.mute, .unmute, .deafen, .undeafen].contains($0.key) }
            }
        }
        snapshot.buttons = Set(found.keys)
        if snapshot.buttons.isDisjoint(with: [.mute, .unmute]) { snapshot.buttons.insert(.toggleMute) }
        if snapshot.buttons.isDisjoint(with: [.deafen, .undeafen]) { snapshot.buttons.insert(.toggleDeafen) }
        return (found, links)

        func callerAvatar(_ answer: AXUIElement, decline: AXUIElement) -> URL? {
            var parent = answer
            for _ in 0..<12 {
                guard let ref = attribute(parent, kAXParentAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else { break }
                parent = ref as! AXUIElement
                let role = attribute(parent, kAXRoleAttribute) as? String
                if role == "AXWebArea" || role == "AXWindow" { break }
                var stack = [parent], visited = Set<AXUIElement>(), avatars = Set<URL>()
                while let child = stack.popLast(), visited.count < 100 {
                    guard visited.insert(child).inserted else { continue }
                    if attribute(child, kAXRoleAttribute) as? String == "AXImage",
                       let url = attribute(child, kAXURLAttribute) as? URL, url.scheme == "https",
                       ["cdn.discordapp.com", "media.discordapp.net"].contains(url.host?.lowercased() ?? ""),
                       url.path.hasPrefix("/avatars/") || url.path.hasPrefix("/embed/avatars/") {
                        avatars.insert(url)
                    }
                    stack += attribute(child, kAXChildrenAttribute) as? [AXUIElement] ?? []
                }
                if stack.isEmpty && visited.contains(decline) && avatars.count == 1 { return avatars.first }
                if avatars.count > 1 || !stack.isEmpty { break }
            }
            return nil
        }
    }
}
