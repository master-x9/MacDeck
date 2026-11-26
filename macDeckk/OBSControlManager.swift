//
//  OBSControlManager.swift
//  MacDeck (macOS Host)
//
//  Talks to OBS Studio's built-in WebSocket server (obs-websocket v5 —
//  bundled with OBS 28+; enable it in OBS via Tools ▸ WebSocket Server
//  Settings, and set a password there to match what's entered in MacDeck).
//  This is OBS's own official local automation API — not screen-scraping,
//  not a private API.
//
//  Auto-connects only while OBS is running (see AppFrontmostMonitor), and
//  publishes a dynamically-generated DeckPage — one tile per scene, plus
//  Record / Stream / Replay Buffer / Mic toggles — the same pattern
//  RunningAppsMonitor uses for its page. DeckNetworkManager auto-switches
//  the phone to this page when OBS becomes the frontmost app.
//

import Foundation
import AppKit
import CryptoKit
import Combine
import Security

@MainActor
final class OBSControlManager: NSObject, ObservableObject {
    static let shared = OBSControlManager()

    /// OBS Studio's bundle identifier.
    static let obsBundleID = "com.obsproject.obs-studio"
    static let obsPageID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

    @Published private(set) var isConnected = false
    @Published private(set) var scenes: [String] = []
    @Published private(set) var currentScene: String?
    @Published private(set) var isRecording = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isReplayBufferActive = false
    @Published private(set) var lastError: String?

    /// Dynamically-generated page shown on the phone while OBS is running
    /// and connected. `nil` while disconnected — PageStore only surfaces
    /// this page when there's actually something to show.
    @Published private(set) var obsPage: DeckPage?

    // MARK: - Settings

    private static let hostDefaultsKey = "macdeck.obs.host"
    private static let portDefaultsKey = "macdeck.obs.port"
    private static let keychainService = "com.macdeck.obsWebSocketPassword"

    var host: String {
        get { UserDefaults.standard.string(forKey: Self.hostDefaultsKey) ?? "127.0.0.1" }
        set { UserDefaults.standard.set(newValue, forKey: Self.hostDefaultsKey) }
    }

    var port: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
            return stored == 0 ? 4455 : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.portDefaultsKey) }
    }

    func hasPassword() -> Bool { retrievePassword() != nil }

    /// Updates the stored WebSocket password and reconnects with it.
    func setPassword(_ password: String?) {
        if let password, !password.isEmpty {
            savePassword(password)
        } else {
            deletePassword()
        }
        disconnect()
        if AppFrontmostMonitor.shared.isRunning(Self.obsBundleID) { connect() }
    }

    /// Call after changing host/port in settings.
    func reconnect() {
        disconnect()
        if AppFrontmostMonitor.shared.isRunning(Self.obsBundleID) { connect() }
    }

    // MARK: - Private state

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var identified = false
    private var micInputName: String?
    private var frontmostCancellable: AnyCancellable?
    private var reconnectWorkItem: DispatchWorkItem?
    private var pendingRequests: [String: (requestType: String, completion: (([String: Any]?) -> Void)?)] = [:]

    private override init() {
        super.init()
        // Only try to connect while OBS is actually running — no idle
        // reconnect loop hammering localhost while the app is closed.
        frontmostCancellable = AppFrontmostMonitor.shared.$runningBundleIDs
            .map { $0.contains(Self.obsBundleID) }
            .removeDuplicates()
            .sink { [weak self] running in
                guard let self else { return }
                if running {
                    self.connect()
                } else {
                    self.disconnect()
                }
            }
        if AppFrontmostMonitor.shared.isRunning(Self.obsBundleID) {
            connect()
        }
    }

    // MARK: - Connection

    private func connect() {
        guard webSocketTask == nil else { return }
        guard let url = URL(string: "ws://\(host):\(port)") else { return }
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.webSocketTask = task
        self.identified = false
        task.resume()
        receiveLoop()
    }

    private func disconnect() {
        reconnectWorkItem?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        identified = false
        isConnected = false
        obsPage = nil
        pendingRequests.removeAll()
    }

    private func scheduleReconnect() {
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        identified = false
        isConnected = false
        obsPage = nil
        pendingRequests.removeAll()
        guard AppFrontmostMonitor.shared.isRunning(Self.obsBundleID) else { return }
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = work
        // OBS may still be launching, or the WebSocket server may not be
        // enabled — a short retry loop rather than a tight one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func receiveLoop() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.webSocketTask === task else { return }
                switch result {
                case .failure(let error):
                    self.lastError = task.closeCode.rawValue == 4009 ? "OBS rejected the WebSocket password." : error.localizedDescription
                    self.scheduleReconnect()
                    return
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handleMessage(text) }
                    @unknown default:
                        break
                    }
                }
                // Keep listening as long as this is still the active task
                // (guards against a stale receive loop from a task that's
                // already been replaced by a reconnect).
                if self.webSocketTask === task {
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
            if let error {
                NSLog("MacDeck[OBS]: send failed: \(error)")
            }
        }
    }

    // MARK: - Protocol (obs-websocket v5)

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? Int,
              let d = obj["d"] as? [String: Any] else { return }

        switch op {
        case 0: handleHello(d)          // Hello
        case 2:                          // Identified
            identified = true
            isConnected = true
            lastError = nil
            refreshEverything()
        case 5: handleEvent(d)          // Event
        case 7: handleRequestResponse(d) // RequestResponse
        default: break
        }
    }

    private func handleHello(_ d: [String: Any]) {
        var identifyPayload: [String: Any] = [
            "rpcVersion": 1,
            "eventSubscriptions": 1 | 4 | 64, // General | Scenes | Outputs
        ]
        if let auth = d["authentication"] as? [String: Any],
           let challenge = auth["challenge"] as? String,
           let salt = auth["salt"] as? String {
            guard let password = retrievePassword() else {
                lastError = "OBS has a WebSocket password set — add the same password in MacDeck's OBS settings."
                disconnect()
                return
            }
            identifyPayload["authentication"] = Self.computeAuth(password: password, salt: salt, challenge: challenge)
        }
        sendRaw(["op": 1, "d": identifyPayload])
    }

    private static func computeAuth(password: String, salt: String, challenge: String) -> String {
        func sha256Base64(_ string: String) -> String {
            Data(SHA256.hash(data: Data(string.utf8))).base64EncodedString()
        }
        let secret = sha256Base64(password + salt)
        return sha256Base64(secret + challenge)
    }

    private func sendRequest(_ type: String, data reqData: [String: Any]? = nil, completion: (([String: Any]?) -> Void)? = nil) {
        guard identified else { return }
        let requestId = UUID().uuidString
        pendingRequests[requestId] = (type, completion)
        var d: [String: Any] = ["requestType": type, "requestId": requestId]
        if let reqData { d["requestData"] = reqData }
        sendRaw(["op": 6, "d": d])
    }

    private func handleRequestResponse(_ d: [String: Any]) {
        guard let requestId = d["requestId"] as? String,
              let pending = pendingRequests.removeValue(forKey: requestId) else { return }
        let status = d["requestStatus"] as? [String: Any]
        if (status?["result"] as? Bool) != true {
            NSLog("MacDeck[OBS]: \(pending.requestType) failed: \(status?["comment"] ?? "unknown")")
        }
        pending.completion?(d["responseData"] as? [String: Any])
    }

    private func handleEvent(_ d: [String: Any]) {
        guard let eventType = d["eventType"] as? String else { return }
        let eventData = d["eventData"] as? [String: Any] ?? [:]
        switch eventType {
        case "CurrentProgramSceneChanged":
            currentScene = eventData["sceneName"] as? String
            rebuildPage()
        case "SceneListChanged":
            refreshScenes()
        case "RecordStateChanged":
            isRecording = (eventData["outputActive"] as? Bool) ?? isRecording
            rebuildPage()
        case "StreamStateChanged":
            isStreaming = (eventData["outputActive"] as? Bool) ?? isStreaming
            rebuildPage()
        case "ReplayBufferStateChanged":
            isReplayBufferActive = (eventData["outputActive"] as? Bool) ?? isReplayBufferActive
            rebuildPage()
        default:
            break
        }
    }

    private func refreshEverything() {
        refreshScenes()
        sendRequest("GetRecordStatus") { [weak self] data in
            self?.isRecording = (data?["outputActive"] as? Bool) ?? false
            self?.rebuildPage()
        }
        sendRequest("GetStreamStatus") { [weak self] data in
            self?.isStreaming = (data?["outputActive"] as? Bool) ?? false
            self?.rebuildPage()
        }
        sendRequest("GetReplayBufferStatus") { [weak self] data in
            self?.isReplayBufferActive = (data?["outputActive"] as? Bool) ?? false
            self?.rebuildPage()
        }
        sendRequest("GetSpecialInputs") { [weak self] data in
            self?.micInputName = data?["mic1"] as? String
            self?.rebuildPage()
        }
    }

    private func refreshScenes() {
        sendRequest("GetSceneList") { [weak self] data in
            guard let self else { return }
            let list = (data?["scenes"] as? [[String: Any]]) ?? []
            // obs-websocket returns scenes with the highest sceneIndex
            // (bottom of OBS's own list) first — reverse so tiles read in
            // the same top-to-bottom order OBS shows them in.
            self.scenes = list.compactMap { $0["sceneName"] as? String }.reversed()
            self.currentScene = data?["currentProgramSceneName"] as? String
            self.rebuildPage()
        }
    }

    // MARK: - Executing actions (called from SystemActionEngine)

    func execute(_ action: OBSControlAction) {
        switch action {
        case .switchScene(let name):
            sendRequest("SetCurrentProgramScene", data: ["sceneName": name])
        case .startRecording: sendRequest("StartRecord")
        case .stopRecording: sendRequest("StopRecord")
        case .toggleRecording:
            sendRequest("ToggleRecord")
        case .toggleStreaming:
            sendRequest("ToggleStream")
        case .toggleReplayBuffer:
            sendRequest("ToggleReplayBuffer")
        case .toggleMicMute:
            guard let micInputName else { return }
            sendRequest("ToggleInputMute", data: ["inputName": micInputName])
        }
    }

    // MARK: - Page generation

    private func rebuildPage() {
        guard isConnected else { obsPage = nil; return }

        var tiles: [DeckTile?] = Array(repeating: nil, count: DeckPage.slotCount)
        var slot = 0

        func addTile(_ type: TileType, label: String? = nil, symbol: String, tint: NSColor, active: Bool = false) {
            guard slot < DeckPage.slotCount else { return }
            let icon = SFSymbolIconGenerator.generate(
                symbolName: symbol,
                foreground: .white,
                background: active ? tint : tint.withAlphaComponent(0.35)
            )
            tiles[slot] = DeckTile(slotIndex: slot, tileType: type, customLabel: label, iconData: icon)
            slot += 1
        }

        addTile(.obsControl(action: isRecording ? .stopRecording : .startRecording), symbol: isRecording ? "record.circle.fill" : "record.circle", tint: .systemRed, active: isRecording)
        addTile(.obsControl(action: .toggleStreaming), symbol: "dot.radiowaves.left.and.right", tint: .systemPurple, active: isStreaming)
        addTile(.obsControl(action: .toggleReplayBuffer), symbol: "gobackward", tint: .systemOrange, active: isReplayBufferActive)
        if micInputName != nil {
            addTile(.obsControl(action: .toggleMicMute), symbol: "mic", tint: .systemGreen)
        }

        // Both navigation buttons fit on the smallest phone grid, even for large collections.
        if scenes.count > 10 - slot, let currentScene, let index = scenes.firstIndex(of: currentScene) {
            let previous = scenes[(index + scenes.count - 1) % scenes.count]
            let next = scenes[(index + 1) % scenes.count]
            addTile(.obsControl(action: .switchScene(name: previous)), label: "Previous Scene", symbol: "chevron.left", tint: .systemBlue)
            addTile(.obsControl(action: .switchScene(name: next)), label: "Next Scene", symbol: "chevron.right", tint: .systemBlue)
        }
        for scene in scenes {
            addTile(
                .obsControl(action: .switchScene(name: scene)),
                label: scene,
                symbol: scene == currentScene ? "checkmark.square.fill" : "square",
                tint: .systemBlue,
                active: scene == currentScene
            )
        }

        obsPage = DeckPage(id: Self.obsPageID, name: "OBS", pageNumber: -2, tiles: tiles)
    }

    // MARK: - Keychain (password only — host/port aren't sensitive)

    private func savePassword(_ password: String) {
        let account = NSUserName()
        guard let data = password.data(using: .utf8) else { return }
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

    private func retrievePassword() -> String? {
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

    private func deletePassword() {
        let account = NSUserName()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
