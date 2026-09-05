//
//  DeckNetworkManager.swift
//  MacDeck (macOS Host)
//
//  Advertises MacDeck over Bonjour as `_macdeck._tcp`, runs a
//  WebSocket server on port 62233 via Network.framework, and bridges
//  incoming phone commands to SystemActionEngine.
//
//  NOTE: requires the "Incoming Connections (Server)" App Sandbox
//  entitlement, plus NSLocalNetworkUsageDescription and
//  NSBonjourServices (_macdeck._tcp) in Info.plist, or Bonjour
//  advertising will silently fail / the permission prompt won't appear.
//

import Network
import Combine
import Foundation
import SystemConfiguration

struct TrustedDevice: Codable, Identifiable, Hashable {
    var id: String { clientID }
    let clientID: String
    let deviceName: String
    let lastConnected: Date
}

@MainActor
final class TrustedDeviceStore: ObservableObject {
    static let shared = TrustedDeviceStore()

    @Published private(set) var devices: [TrustedDevice] = []

    private let storeURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jk.MacDeck"
        let directoryURL = appSupport.appendingPathComponent(bundleID)

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        storeURL = directoryURL.appendingPathComponent("TrustedDevices.json")

        load()
    }

    func isTrusted(clientID: String) -> Bool {
        devices.contains { $0.clientID == clientID }
    }

    func trust(clientID: String, deviceName: String) {
        var newDevices = devices.filter { $0.clientID != clientID }
        newDevices.append(TrustedDevice(clientID: clientID, deviceName: deviceName, lastConnected: Date()))
        devices = newDevices
        save()
    }

    func forget(clientID: String) {
        devices.removeAll { $0.clientID == clientID }
        save()
    }

    func recordConnection(clientID: String) {
        guard let index = devices.firstIndex(where: { $0.clientID == clientID }) else { return }
        let device = devices[index]
        devices.remove(at: index)
        devices.append(TrustedDevice(clientID: device.clientID, deviceName: device.deviceName, lastConnected: Date()))
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let loaded = try? JSONDecoder().decode([TrustedDevice].self, from: data) else {
            devices = []
            return
        }
        devices = loaded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

@MainActor
final class DeckNetworkManager: ObservableObject {

    nonisolated(unsafe) var debugLogging: Bool = false

    private nonisolated static let iconDataRegex: NSRegularExpression? = try? NSRegularExpression(pattern: "\"iconData\":\"[^\"]+\"", options: [])

    nonisolated private func debugLog(_ message: @autoclosure () -> String) {
        guard debugLogging else { return }
        #if DEBUG
        NSLog("MacDeck[NET]: \(message())")
        #endif
    }

    nonisolated private func redacted(jsonString: String) -> String {
        guard let regex = Self.iconDataRegex else { return jsonString }
        let range = NSRange(jsonString.startIndex..<jsonString.endIndex, in: jsonString)
        return regex.stringByReplacingMatches(in: jsonString, options: [], range: range, withTemplate: "\"iconData\":\"<base64 redacted>\"")
    }

    // MARK: - Machine Identity

    private static let macIDKey = "MacDeckHostUUID"

    /// Persistent unique identifier for this Mac instance so clients can bind to it.
    nonisolated static var hostID: String {
        if let saved = UserDefaults.standard.string(forKey: macIDKey) {
            return saved
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: macIDKey)
        return newID
    }

    /// User-friendly localized Mac computer name for unique Bonjour advertising.
    nonisolated static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let name = Host.current().localizedName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return "MacDeck"
    }

    enum ConnectionStatus: Equatable {
        case disconnected
        case waiting
        case awaitingHello
        case awaitingApproval(clientID: String, deviceName: String)
        case connected(deviceName: String)
    }

    @Published private(set) var status: ConnectionStatus = .disconnected

    /// Supplies the full list of pages setup by the user.
    var pagesProvider: (() -> [DeckPage])?
    
    /// Triggered when the client specifies its grid size.
    var onGridRowsChanged: ((Int) -> Void)?

    /// Resolves the page (if any) that should be auto-shown because a given
    /// app just became frontmost on the Mac — wired to
    /// `PageStore.autoSwitchPageID(forFrontmostBundleID:)` by MacDeckApp.
    var autoSwitchPageResolver: ((String?) -> UUID?)?

    /// Lets the Mac-side UI mirror an automatic page switch (so the sidebar
    /// selection follows what the phone just jumped to).
    var onAutoSwitchPage: ((UUID) -> Void)?

    /// Where TRIGGER_SLOT commands get routed. Defaults to the shared engine.
    var actionEngine: SystemActionEngine = .shared

    /// The required protocol version for a client to connect.
    let requiredProtocolVersion = 1

    private let serviceType = "_macdeck._tcp"
    private let port: NWEndpoint.Port = 62233
    private let queue = DispatchQueue(label: "com.macdeck.network")

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var activeClientID: String?
    private var pendingConnection: NWConnection?
    private var pendingClientID: String?

    private var restartWorkItem: DispatchWorkItem?
    private var lockStateCancellable: AnyCancellable?
    private var frontmostAppCancellable: AnyCancellable?
    private var lastAutoSwitchedPageID: UUID?

    // MARK: - Lifecycle

    func start() {
        if lockStateCancellable == nil {
            // Push lock-state changes to the phone as they happen, and switch
            // it to/from the locked-page layout. Owned here (not in the UI
            // layer) so it keeps working even if no window is focused.
            lockStateCancellable = RemoteUnlockManager.shared.$isLocked
                .removeDuplicates()
                .sink { [weak self] isLocked in
                    Task { @MainActor [weak self] in
                        self?.handleLockStateChange(isLocked)
                    }
                }
        }

        if frontmostAppCancellable == nil {
            // Auto-switch the phone's page when a "trigger" app (a
            // per-app custom page, or OBS/Discord) becomes frontmost.
            frontmostAppCancellable = AppFrontmostMonitor.shared.$frontmostBundleID
                .removeDuplicates()
                .sink { [weak self] bundleID in
                    Task { @MainActor [weak self] in
                        self?.handleFrontmostAppChange(bundleID)
                    }
                }
        }

        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        params.acceptLocalOnly = false

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 1024 * 1024 * 50 // 50MB
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            let listener = try NWListener(using: params, on: port)

            var txtRecord = NWTXTRecord()
            txtRecord["name"] = Self.computerName
            txtRecord["hostId"] = Self.hostID
            txtRecord["version"] = String(requiredProtocolVersion)
            txtRecord["model"] = "Mac"

            // Register service with the Mac's localized computer name and rich TXT record
            // so multiple Macs on the same LAN advertise distinct, identifiable Bonjour records.
            listener.service = NWListener.Service(name: Self.computerName, type: serviceType, txtRecord: txtRecord)

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.handleNewConnection(connection) }
            }
            listener.serviceRegistrationUpdateHandler = { change in
                switch change {
                case .add(let endpoint):
                    NSLog("MacDeck: Bonjour service registered at \(endpoint) [\(Self.computerName)]")
                case .remove(let endpoint):
                    NSLog("MacDeck: Bonjour service unregistered at \(endpoint)")
                @unknown default:
                    break
                }
            }

            debugLog("Starting listener on port \(port) service type \(serviceType) [\(Self.computerName)]")
            listener.start(queue: queue)
            self.listener = listener
            status = .waiting
        } catch {
            NSLog("MacDeck: failed to start listener: \(error)")
            status = .disconnected
            scheduleRestart()
        }
    }

    func stop() {
        restartWorkItem?.cancel()
        pendingConnection?.cancel()
        pendingConnection = nil
        pendingClientID = nil
        activeConnection?.cancel()
        activeConnection = nil
        activeClientID = nil
        listener?.cancel()
        listener = nil
        status = .disconnected
    }

    private func scheduleRestart(after seconds: TimeInterval = 3) {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Listener state

    private func handleListenerState(_ state: NWListener.State) {
        // NOTE: This is already called on @MainActor (via Task @MainActor in the
        // stateUpdateHandler), but we still use DispatchQueue.main.async for the
        // @Published mutations so they always land outside any active SwiftUI
        // render pass — preventing the "Publishing changes from within view updates" warning.
        switch state {
        case .ready:
            debugLog("Listener ready (activeConnection == nil? \(activeConnection == nil))")
            if activeConnection == nil && pendingConnection == nil {
                DispatchQueue.main.async { [weak self] in self?.status = .waiting }
            }
        case .failed(let error):
            debugLog("Listener failed: \(error)")
            NSLog("MacDeck: listener failed: \(error)")
            DispatchQueue.main.async { [weak self] in self?.status = .disconnected }
            scheduleRestart()
        case .cancelled:
            debugLog("Listener cancelled")
            DispatchQueue.main.async { [weak self] in self?.status = .disconnected }
        default:
            break
        }
    }

    // MARK: - Connections

    private func handleNewConnection(_ connection: NWConnection) {
        debugLog("New connection from: \(deviceDisplayName(for: connection))")

        // Two-stage handshake: Do NOT preempt activeConnection immediately.
        // Instead, place in pendingConnection while awaiting HELLO handshake.
        if let oldPending = pendingConnection, oldPending !== activeConnection {
            oldPending.cancel()
        }
        pendingConnection = connection
        pendingClientID = nil

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.handleConnectionState(state, for: connection) }
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, for connection: NWConnection) {
        switch state {
        case .ready:
            debugLog("Connection ready (\(deviceDisplayName(for: connection))); awaiting HELLO from client")
            if activeConnection == nil {
                DispatchQueue.main.async { [weak self] in self?.status = .awaitingHello }
            }
            receiveLoop(on: connection)
        case .failed, .cancelled:
            debugLog("Connection failed/cancelled (active? \(activeConnection === connection), pending? \(pendingConnection === connection))")
            if pendingConnection === connection {
                pendingConnection = nil
                pendingClientID = nil
            }
            if activeConnection === connection {
                activeConnection = nil
                activeClientID = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if case .awaitingApproval = self.status {
                        if self.pendingConnection == nil {
                            self.status = .waiting
                        }
                    } else {
                        self.status = .waiting
                    }
                }
            } else if activeConnection == nil && pendingConnection == nil {
                DispatchQueue.main.async { [weak self] in self?.status = .waiting }
            }
        default:
            break
        }
    }

    nonisolated private func deviceDisplayName(for connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint {
            return "\(host)"
        }
        return "Phone"
    }

    // MARK: - Receiving

    private func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if let s = String(data: data, encoding: .utf8) {
                    self.debugLog("Received raw: \(s)")
                } else {
                    self.debugLog("Received \(data.count) bytes (non-UTF8)")
                }
                Task { @MainActor in self.handleIncoming(data, from: connection) }
            }
            if let error {
                self.debugLog("Receive error on \(self.deviceDisplayName(for: connection)): \(error)")
                Task { @MainActor in
                    if self.pendingConnection === connection {
                        self.pendingConnection = nil
                        self.pendingClientID = nil
                    }
                    if self.activeConnection === connection {
                        self.activeConnection?.cancel()
                        self.activeConnection = nil
                        self.activeClientID = nil
                        self.status = .waiting
                    }
                }
                return
            }
            // Only keep listening while this connection is still active or pending.
            Task { @MainActor in
                if self.activeConnection === connection || self.pendingConnection === connection {
                    self.receiveLoop(on: connection)
                }
            }
        }
    }

    private func handleIncoming(_ data: Data, from connection: NWConnection) {
        guard let command = try? JSONDecoder().decode(ClientCommand.self, from: data) else {
            if let s = String(data: data, encoding: .utf8) {
                // A short non-JSON string is almost certainly the WebSocket close-frame
                // reason (e.g. "User disconnected" from OkHttp). Log it helpfully rather
                // than as a "malformed message" and return — the .cancelled state event
                // for this connection will arrive immediately after and do the real cleanup.
                if !s.hasPrefix("{") && s.count < 256 {
                    NSLog("MacDeck: WebSocket close reason received: \(s)")
                } else {
                    debugLog("Malformed incoming JSON: \(s)")
                    NSLog("MacDeck: received malformed message: \(s)")
                }
            } else {
                debugLog("Malformed incoming data (\(data.count) bytes)")
                NSLog("MacDeck: received malformed message: <binary \(data.count) bytes>")
            }
            return
        }

        debugLog("Decoded command: \(command)")

        switch command {
        case .hello(let clientID, let deviceName, let protocolVersion, let gridRows):
            handleHello(clientID: clientID, deviceName: deviceName, protocolVersion: protocolVersion, gridRows: gridRows, on: connection)
            return
        default:
            break
        }

        // Only process application commands from the active authenticated connection
        guard activeConnection === connection, case .connected = status else {
            NSLog("MacDeck: ignoring command \(command) because connection is not the active .connected session")
            return
        }

        switch command {
        case .triggerSlot(let pageID, let slotIndex):
            // The locked-screen page is fixed and not part of the user's
            // editable page list, so it's resolved here rather than via
            // pagesProvider — this is what lets the "Unlock Mac" tile (and
            // the rest of the locked layout) work while the Mac is locked.
            if pageID == LockedPageProvider.lockedPageID {
                let lockedTiles = LockedPageProvider.lockedPage.tiles
                guard slotIndex >= 0, slotIndex < lockedTiles.count,
                      let tile = lockedTiles[slotIndex] else {
                    NSLog("MacDeck: dropping invalid locked-page slot execution")
                    return
                }
                actionEngine.execute(tile.tileType)
                return
            }

            guard let pages = pagesProvider?(),
                  let page = pages.first(where: { $0.id == pageID }),
                  slotIndex >= 0, slotIndex < page.tiles.count,
                  let tile = page.tiles[slotIndex] else {
                NSLog("MacDeck: dropping invalid trigger slot execution")
                return
            }
            actionEngine.execute(tile.tileType)
        case .requestSync:
            sendAllPages()
        case .ping:
            send(.pong, to: connection)
        case .hello:
            break // handled above
        }
    }

    private func handleHello(clientID: String, deviceName: String, protocolVersion: Int, gridRows: Int, on connection: NWConnection) {
        debugLog("HELLO from \(deviceName) id=\(clientID) proto=\(protocolVersion)")

        onGridRowsChanged?(gridRows)

        if protocolVersion != requiredProtocolVersion {
            debugLog("Version mismatch: client=\(protocolVersion) required=\(requiredProtocolVersion)")
            send(.versionMismatch(requiredVersion: requiredProtocolVersion), to: connection)
            connection.cancel()
            if pendingConnection === connection {
                pendingConnection = nil
                pendingClientID = nil
            }
            if activeConnection === connection {
                activeConnection = nil
                activeClientID = nil
                status = .waiting
            }
            return
        }

        if TrustedDeviceStore.shared.isTrusted(clientID: clientID) {
            TrustedDeviceStore.shared.recordConnection(clientID: clientID)

            // Safely promote this connection to activeConnection
            if let old = activeConnection, old !== connection {
                old.cancel()
            }
            activeConnection = connection
            activeClientID = clientID
            if pendingConnection === connection {
                pendingConnection = nil
                pendingClientID = nil
            }

            send(.pairingApproved, to: connection)
            status = .connected(deviceName: deviceName)
            debugLog("Pairing approved for trusted device \(deviceName); sending pages")
            sendAllPages()
            handleLockStateChange(RemoteUnlockManager.shared.isLocked)
        } else {
            debugLog("Awaiting approval for device \(deviceName) id=\(clientID)")
            pendingConnection = connection
            pendingClientID = clientID
            send(.pairingPending, to: connection)
            status = .awaitingApproval(clientID: clientID, deviceName: deviceName)
        }
    }

    func approvePairing(clientID: String, deviceName: String) {
        guard case .awaitingApproval(let currentClientID, _) = status, currentClientID == clientID else { return }
        debugLog("Approving pairing for \(deviceName) id=\(clientID)")
        TrustedDeviceStore.shared.trust(clientID: clientID, deviceName: deviceName)

        if let pending = pendingConnection {
            if let old = activeConnection, old !== pending {
                old.cancel()
            }
            activeConnection = pending
            activeClientID = clientID
            pendingConnection = nil
            pendingClientID = nil
        }

        send(.pairingApproved)
        status = .connected(deviceName: deviceName)
        debugLog("Sending pages after approval")
        sendAllPages()
        handleLockStateChange(RemoteUnlockManager.shared.isLocked)
    }

    func denyPairing() {
        guard case .awaitingApproval = status else { return }
        debugLog("Denying pairing and closing connection")
        if let pending = pendingConnection {
            send(.pairingDenied, to: pending)
            pending.cancel()
            pendingConnection = nil
            pendingClientID = nil
        }
        if let active = activeConnection {
            let activeName = deviceDisplayName(for: active)
            status = .connected(deviceName: activeName)
        } else {
            status = .waiting
        }
    }

    // MARK: - Sending

    private func sendAllPages() {
        // Only send when there's actually an active paired session — avoids
        // queueing large payloads onto a connection that's mid-handshake or gone.
        guard case .connected = status else { return }
        #if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
        #endif
        guard let pages = pagesProvider?() else { return }
        let populatedPages = pages.filter { page in 
            page.tiles.contains(where: { $0 != nil })
        }
        let pagesToSend = populatedPages.isEmpty && !pages.isEmpty ? [pages[0]] : populatedPages
        debugLog("Broadcasting \(pagesToSend.count) page(s) to client")
        send(.pageSync(pagesToSend))
        #if DEBUG
        let end = CFAbsoluteTimeGetCurrent()
        NSLog("MacDeck: sendAllPages took \((end - start) * 1000)ms")
        #endif
    }

    /// Tells the phone the Mac's current lock state, and switches it to the
    /// locked layout (or back to a normal page) to match. Called both when
    /// the lock state actually changes and right after a device connects,
    /// so a freshly-opened phone app is never showing a stale page.
    private func handleLockStateChange(_ isLocked: Bool) {
        guard case .connected = status else { return }
        debugLog("Lock state changed: isLocked=\(isLocked)")
        send(.lockStateChanged(isLocked: isLocked))
        if isLocked {
            send(.switchToPage(pageID: LockedPageProvider.lockedPageID))
        } else if let pages = pagesProvider?() {
            let populatedPages = pages.filter { page in 
                page.tiles.contains(where: { $0 != nil })
            }
            let targetPage = populatedPages.first ?? pages.first
            if let targetPage {
                send(.switchToPage(pageID: targetPage.id))
            }
        }
    }

    /// Auto-switches the phone to a "trigger" page (a per-app custom page,
    /// or the OBS/Discord page) when a matching app becomes frontmost.
    /// Never fires while the Mac is locked — the locked layout always wins
    /// — and only sends when the resolved target actually changes, so
    /// switching between two unrelated apps doesn't spam redundant
    /// `switchToPage` messages.
    private func handleFrontmostAppChange(_ bundleID: String?) {
        guard case .connected = status else { return }
        guard !RemoteUnlockManager.shared.isLocked else { return }
        guard let targetID = autoSwitchPageResolver?(bundleID) else { return }
        guard targetID != lastAutoSwitchedPageID else { return }
        lastAutoSwitchedPageID = targetID
        debugLog("Auto-switching to page \(targetID) for frontmost app \(bundleID ?? "nil")")
        send(.switchToPage(pageID: targetID))
        onAutoSwitchPage?(targetID)
    }

    func send(_ message: ServerMessage, to connection: NWConnection? = nil) {
        guard let targetConnection = connection ?? activeConnection else { return }
        let shouldLog = debugLogging
        queue.async { [weak self] in
            guard let self = self else { return }
            // Guard against sending on a connection that is no longer ready —
            // prevents the "nw_connection_copy_protocol_metadata on unconnected
            // nw_connection" log spam and avoids pointless send-on-cancelled errors.
            guard targetConnection.state == .ready else {
                self.debugLog("Skipping send — connection not ready (state: \(targetConnection.state))")
                return
            }
            do {
                let data = try JSONEncoder().encode(message)
                if shouldLog {
                    if let s = String(data: data, encoding: .utf8) {
                        let safeMessage = self.redacted(jsonString: s)
                        self.debugLog("Sending: \(safeMessage)")
                    } else {
                        self.debugLog("Sending message (\(data.count) bytes)")
                    }
                }
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "msg-\(UUID().uuidString)", metadata: [metadata])
                targetConnection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                    self.debugLog("Send completed with error: \(String(describing: error))")
                    if let error {
                        NSLog("MacDeck: send failed: \(error)")
                    }
                })
            } catch {
                NSLog("MacDeck: failed to encode message: \(error)")
            }
        }
    }

    private var broadcastWorkItem: DispatchWorkItem?

    /// Call after editing the active page in the UI to push the update live.
    ///
    /// Debounced with a 150ms window — multiple rapid callers (e.g. a drag-drop
    /// that fires broadcastPageUpdate 4–5 times in one event) all collapse into a
    /// single send, preventing TCP congestion from simultaneous large payloads.
    func broadcastPageUpdate() {
        broadcastWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debugLog("broadcastPageUpdate() executing")
            // Hop to main actor to satisfy @MainActor isolation on sendAllPages.
            Task { @MainActor [weak self] in self?.sendAllPages() }
        }
        broadcastWorkItem = work
        // Run on the network queue (not .main) so the debounce timer is decoupled
        // from SwiftUI render cycles and cannot interfere with view updates.
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}


