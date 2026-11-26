import AppKit
import ApplicationServices
import Combine
import OSLog

nonisolated enum DiscordCallButton: String, Codable, CaseIterable {
    case mute, unmute, cameraOn, cameraOff, disconnect, answer, decline, showCall, toggleMute

    var label: String {
        switch self {
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
        case .showCall: "phone.arrow.up.right"
        case .toggleMute: "mic.circle"
        case .mute: "mic.slash"
        case .unmute: "mic"
        case .cameraOn: "video"
        case .cameraOff: "video.slash"
        case .disconnect, .decline: "phone.down.fill"
        case .answer: "phone.fill"
        }
    }

    init?(accessibleName: String) {
        let name = accessibleName.split(whereSeparator: \.isNewline).first.map(String.init)?
            .components(separatedBy: " (").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "mute", "mute microphone", "mute audio", "mute yourself": self = .mute
        case "unmute", "unmute microphone", "unmute audio", "unmute yourself": self = .unmute
        case "turn on camera", "turn camera on", "start video", "enable camera", "turn on video": self = .cameraOn
        case "turn off camera", "turn camera off", "stop video", "disable camera", "turn off video": self = .cameraOff
        case "disconnect", "leave call", "disconnect from voice", "disconnect call", "end call", "hang up", "leave voice channel": self = .disconnect
        case "accept", "accept call", "answer call", "join call": self = .answer
        case "decline", "decline call": self = .decline
        default: return nil
        }
    }
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
    private var buttons = Set<DiscordCallButton>()
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
        guard enabled else { update([], status: .disabled); return }
        guard let pid = Self.discordPID else { update([], status: .waitingForApp); return }
        guard AXIsProcessTrusted() else { update([], status: .needsAccessibility); return }
        scanning = true
        queue.async {
            var summary = ""
            let found = Set(Self.controls(pid: pid, summary: &summary).keys)
            let scanSummary = summary
            Task { @MainActor in
                self.scanning = false
                guard self.enabled, Self.discordPID == pid else { self.refresh(); return }
                if scanSummary != self.lastScanSummary {
                    self.lastScanSummary = scanSummary
                    self.logger.info("Discord accessibility scan: \(scanSummary, privacy: .public)")
                }
                self.update(found.isEmpty ? [.showCall, .toggleMute] : found, status: found.isEmpty ? .waitingForCall : .active)
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

    private func update(_ found: Set<DiscordCallButton>, status message: Status) {
        if status != message {
            status = message
            logger.notice("\(message.rawValue, privacy: .public)")
        }
        guard buttons != found else { return }
        buttons = found
        guard !found.isEmpty else { page = nil; return }
        let name = message == .waitingForCall ? "Discord Controls" : (found.contains(.answer) ? "Incoming Discord Call" : "Discord Call")
        var result = DeckPage(id: Self.pageID, name: name, pageNumber: -4)
        for (slot, button) in DiscordCallButton.allCases.enumerated() where found.contains(button) {
            let icon = SFSymbolIconGenerator.generate(symbolName: button.symbol, foreground: .white, background: .systemIndigo)
            result.tiles[slot] = DeckTile(slotIndex: slot, tileType: .discordControl(action: .call(button)), customLabel: button.label, iconData: icon)
        }
        page = result
    }

    func press(_ button: DiscordCallButton) {
        guard enabled, let pid = Self.discordPID else { return }
        if button == .showCall || button == .toggleMute {
            guard AXIsProcessTrusted() else { return }
            let key: CGKeyCode = button == .showCall ? 9 : 46  // V, M
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
            if let element = Self.controls(pid: pid, summary: &summary)[button] {
                AXUIElementPerformAction(element, kAXPressAction as CFString)
            }
        }
    }

    private nonisolated static func controls(pid: pid_t, summary: inout String) -> [DiscordCallButton: AXUIElement] {
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
        var nodes = roots
        var found: [DiscordCallButton: AXUIElement] = [:]
        var buttonCount = 0
        var webAreas = 0
        var hints = Set<String>()
        let keys = [kAXRoleAttribute, kAXChildrenAttribute] as CFArray
        var index = 0
        while index < nodes.count && seen.count < 16000 {
            let node = nodes[index]
            index += 1
            guard seen.insert(node).inserted else { continue }
            var values: CFArray?
            AXUIElementCopyMultipleAttributeValues(node, keys, [], &values)
            let attrs = values as? [Any] ?? []
            let role = attrs.first as? String ?? attribute(node, kAXRoleAttribute) as? String
            let children = attrs.last as? [AXUIElement] ?? attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            nodes.append(contentsOf: children)
            if role == "AXWebArea" {
                webAreas += 1
                // Chromium can expose buttons through semantic search even when a
                // virtualized subtree is absent from AXChildren.
                let query: [String: Any] = ["AXSearchKey": "AXButtonSearchKey", "AXDirection": "AXDirectionNext", "AXResultsLimit": 1024]
                var result: CFTypeRef?
                AXUIElementCopyParameterizedAttributeValue(node, "AXUIElementsForSearchPredicate" as CFString, query as CFDictionary, &result)
                nodes.append(contentsOf: result as? [AXUIElement] ?? [])
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
                found[button == .mute && checked?.boolValue == true ? .unmute : button] = node
                break
            }
        }
        summary = "roots=\(roots.count) nodes=\(seen.count) webAreas=\(webAreas) buttons=\(buttonCount) terms=\(hints.sorted()) actions=\(found.keys.map(\.rawValue).sorted())"
        let hasVoiceControls = found[.mute] != nil || found[.unmute] != nil
        if found[.disconnect] != nil || (hasVoiceControls && (found[.cameraOn] != nil || found[.cameraOff] != nil || hints.contains("voice connected"))) {
            return found.filter { $0.key != .answer && $0.key != .decline }
        }
        if found[.answer] != nil && found[.decline] != nil { return found.filter { $0.key == .answer || $0.key == .decline } }
        return [:]
    }
}
