//
//  ContentView.swift
//  MacDeck (macOS Host)
//
//  Root view: Professional NavigationSplitView with custom page manager sidebar,
//  live deck hardware canvas, tactile 2×5 slot grid, and integrated Tile Library drawer.
//

import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: PageStore
    @EnvironmentObject var network: DeckNetworkManager

    // MARK: - Local State

    @State private var showAccessibilityBanner = false
    @State private var showingLibrary = true
    @State private var selectedSlot: Int? = nil
    @State private var editingPageID: UUID? = nil
    @State private var editingPageName: String = ""
    @State private var isHoveringNewPage = false
    @State private var isSyncing = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: .phoneDeckNeedsAccessibility)) { _ in
            withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                showAccessibilityBanner = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTileLibraryForSlot)) { notification in
            if let slot = notification.object as? Int {
                selectedSlot = slot
                withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                    showingLibrary = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if SystemActionEngine.shared.refreshAccessibilityPermission(prompt: false) {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                    showAccessibilityBanner = false
                }
            }
        }
        .onAppear {
            _ = SystemActionEngine.shared.refreshAccessibilityPermission(prompt: false)
            if SystemActionEngine.shared.hasAccessibilityPermission {
                showAccessibilityBanner = false
            }
        }
        .onChange(of: store.runningAppsMonitor.runningAppsPage) { _, _ in
            network.broadcastPageUpdate()
        }
        .onChange(of: store.showRunningAppsPage) { _, _ in
            network.broadcastPageUpdate()
        }
        .onChange(of: store.showBrowserControlPage) { _, _ in
            network.broadcastPageUpdate()
        }
        .onChange(of: store.browserMonitor.browserPage) { _, newPage in
            network.broadcastPageUpdate()
            if store.showBrowserControlPage {
                if let newPage {
                    network.send(.switchToPage(pageID: newPage.id))
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Connection Device Card
            deviceConnectionCard
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Button(action: AppUpdates.shared.checkNow) {
                HStack {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text("v\(AppUpdates.version)").foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .padding(.horizontal, 16)

            // Pairing Approval Banner
            if case .awaitingApproval(let clientID, let deviceName) = network.status {
                pairingApprovalBanner(clientID: clientID, deviceName: deviceName)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            // Pages List
            List(selection: $store.selectedPageID) {
                // Section 1: User Configured Pages
                Section {
                    ForEach(store.pages) { page in
                        pageRow(page)
                            .tag(page.id)
                    }
                    .onMove { source, destination in
                        store.movePage(from: source, to: destination)
                        network.broadcastPageUpdate()
                    }
                } header: {
                    HStack {
                        Text("PAGES")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .tracking(0.6)

                        Spacer()

                        Button {
                            withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                                store.addPage()
                                network.broadcastPageUpdate()
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Add new page")
                    }
                }

                // Section 2: Dynamic Live Pages
                if store.showRunningAppsPage || store.showBrowserControlPage || store.showOBSPage || store.showDiscordPage {
                    Section {
                        if store.showBrowserControlPage, let bp = store.browserMonitor.browserPage {
                            browserControlRow(bp)
                                .tag(bp.id)
                        }

                        if store.showRunningAppsPage {
                            runningAppsRow(store.runningAppsMonitor.runningAppsPage)
                                .tag(store.runningAppsMonitor.runningAppsPage.id)
                        }

                        if store.showOBSPage, let op = store.obsMonitor.obsPage {
                            obsRow(op)
                                .tag(op.id)
                        }

                        if store.showDiscordPage, let call = DiscordCalls.shared.page {
                            Label(call.name, systemImage: "phone.fill").tag(call.id)
                        }
                        if store.showDiscordPage, let dp = store.discordMonitor.discordPage {
                            discordRow(dp)
                                .tag(dp.id)
                        }
                    } header: {
                        Text("DYNAMIC STREAMS")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .tracking(0.6)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Sidebar Settings & Security Drawer
            SidebarBottomSection()
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
    }

    // MARK: - Device Connection Card

    private var deviceConnectionCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.18))
                    .frame(width: 32, height: 32)

                Image(systemName: "iphone")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(deviceTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(statusSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if case .connected = network.status {
                Button("Disconnect") { network.disconnectDevice() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Disconnect the phone. Approve its next connection to reconnect.")
            }

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.8), radius: 3)
        }
        .padding(10)
        .proCard(cornerRadius: 12, shadowRadius: 4, shadowY: 2)
    }

    private var statusColor: Color {
        switch network.status {
        case .disconnected: return .red
        case .waiting, .awaitingApproval: return .orange
        case .awaitingHello, .connected: return .green
        }
    }

    private var deviceTitle: String {
        switch network.status {
        case .connected(let deviceName): return deviceName.isEmpty ? "Paired iPhone" : deviceName
        case .awaitingApproval(_, let deviceName): return deviceName
        default: return "MacDeck Client"
        }
    }

    private var statusSubtitle: String {
        switch network.status {
        case .disconnected: return "Searching on Wi-Fi…"
        case .waiting: return "Waiting for connection…"
        case .awaitingHello: return "Handshake in progress…"
        case .awaitingApproval: return "Approval needed"
        case .connected: return "Synchronized & active"
        }
    }

    // MARK: - Page Row

    private func pageRow(_ page: DeckPage) -> some View {
        HStack(spacing: 8) {
            if editingPageID == page.id {
                TextField("Page name", text: $editingPageName, onCommit: {
                    store.renamePage(page.id, to: editingPageName) {
                        network.broadcastPageUpdate()
                    }
                    editingPageID = nil
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            } else {
                // 2×5 Mini Dot Matrix Preview
                miniDotMatrix(for: page)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(page.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if !page.triggerBundleIDs.isEmpty {
                            Image(systemName: "bolt.badge.app.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor)
                                .help("Auto-opens when a linked app launches")
                        }
                    }

                    let tileCount = page.tiles.compactMap { $0 }.count
                    Text("\(tileCount) of \(DeckPage.slotCount) slots")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Rename Page") {
                editingPageName = page.name
                editingPageID = page.id
            }

            Button(page.triggerBundleIDs.isEmpty ? "Auto-Open for App…" : "Change Auto-Open App…") {
                chooseTriggerApp(forPage: page.id)
            }

            if !page.triggerBundleIDs.isEmpty {
                Button("Remove Auto-Open", role: .destructive) {
                    store.setTriggerBundleIDs([], forPage: page.id)
                }
            }

            Divider()

            Button("Delete Page", role: .destructive) {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                    store.deletePage(page.id)
                    network.broadcastPageUpdate()
                }
            }
            .disabled(store.pages.count <= 1)
        }
    }

    /// Lets the user pick any installed app via the standard system open
    /// panel — simpler and more reliable than hand-building a picker over
    /// NSWorkspace's running-apps list, and works for apps that aren't
    /// currently running yet.
    private func chooseTriggerApp(forPage pageID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.message = "MacDeck will switch to this page whenever the chosen app opens."
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        store.setTriggerBundleIDs([bundleID], forPage: pageID)
    }

    private func runningAppsRow(_ page: DeckPage) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.18))
                    .frame(width: 24, height: 24)

                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Running Apps")
                    .font(.system(size: 12, weight: .medium))
                let appCount = page.tiles.compactMap({ $0 }).count
                Text("\(appCount) apps active")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func browserControlRow(_ page: DeckPage) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.18))
                    .frame(width: 24, height: 24)

                Image(systemName: "safari")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(page.name)
                    .font(.system(size: 12, weight: .medium))
                Text("Browser stream")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func obsRow(_ page: DeckPage) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 24, height: 24)

                Image(systemName: "record.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("OBS")
                    .font(.system(size: 12, weight: .medium))
                Text(store.obsMonitor.isRecording ? "Recording" : (store.obsMonitor.isStreaming ? "Streaming" : "Connected"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func discordRow(_ page: DeckPage) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.18))
                    .frame(width: 24, height: 24)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.indigo)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Discord")
                    .font(.system(size: 12, weight: .medium))
                let pinnedCount = store.discordMonitor.pinnedChannels.count
                Text("\(pinnedCount) pinned")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func miniDotMatrix(for page: DeckPage) -> some View {
        let columns = Array(repeating: GridItem(.fixed(3), spacing: 2), count: 5)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<DeckPage.slotCount, id: \.self) { i in
                Circle()
                    .fill(page.tiles[i] != nil ? Color.accentColor : Color.white.opacity(0.18))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(width: 24, height: 12)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.3))
        )
    }

    // MARK: - Pairing Approval Banner

    private func pairingApprovalBanner(clientID: String, deviceName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.shield.checkmark")
                    .foregroundStyle(.orange)
                Text("Pairing Request")
                    .font(.system(size: 11, weight: .bold))
            }

            Text("\"\(deviceName)\" wants to connect.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Allow") {
                    network.approvePairing(clientID: clientID, deviceName: deviceName)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)

                Button("Deny") {
                    network.denyPairing()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .proCard(cornerRadius: 10, strokeColor: Color.orange.opacity(0.4))
    }

    // MARK: - Detail Canvas View

    private var detail: some View {
        ZStack {
            // Subtle dark titanium canvas gradient
            LinearGradient(
                colors: [Color(white: 0.11), Color(white: 0.07)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Toolbar Bar
                topToolbarBar

                // Accessibility Alert Banner
                if showAccessibilityBanner {
                    accessibilityBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Main Stage Content
                if let activePage = store.activePage {
                    VStack(spacing: 12) {
                        // 1. Center Stage Deck Hardware Canvas
                        PhoneFrameGridView(
                            selectedSlot: $selectedSlot,
                            showingLibrary: $showingLibrary
                        )
                        .padding(.top, 14)
                        .padding(.bottom, 6)

                        // 2. Integrated Tile Library Dock (Bottom Drawer)
                        if !isLivePage {
                            TileLibraryView(
                                selectedSlot: $selectedSlot,
                                showingLibrary: $showingLibrary
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("Dynamic Page Mode")
                                    .font(.headline)
                                Text("The host updates these tiles automatically.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Page Selected",
                        systemImage: "square.grid.2x2",
                        description: Text("Select a page from the sidebar or click + to create one.")
                    )
                }
            }
        }
    }

    private var isLivePage: Bool {
        store.activePageIndex == nil
    }

    // MARK: - Top Toolbar Bar

    private var topToolbarBar: some View {
        HStack(spacing: 12) {
            if let activePage = store.activePage {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(activePage.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)

                        if !isLivePage {
                            Button {
                                editingPageName = activePage.name
                                editingPageID = activePage.id
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    let configuredCount = activePage.tiles.compactMap({ $0 }).count
                    Text("\(configuredCount) of \(DeckPage.slotCount) slots configured • Drag controls below onto slots")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Status Pill
            StatusPillView(status: network.status)

            // Sync to Phone Button
            Button {
                isSyncing = true
                network.broadcastPageUpdate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    isSyncing = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .rotationEffect(isSyncing ? .degrees(360) : .degrees(0))
                        .animation(isSyncing ? .linear(duration: 0.6).repeatCount(1, autoreverses: false) : .default, value: isSyncing)

                    Text("Sync to Phone")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Color.black.opacity(0.2)
                .background(.ultraThinMaterial)
        )
        .overlay(
            Divider(),
            alignment: .bottom
        )
    }

    // MARK: - Accessibility Banner

    private var accessibilityBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility Permission Required")
                    .font(.system(size: 12, weight: .bold))
                Text("MacDeck needs Accessibility access to trigger brightness, volume, and media keys.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open System Settings") {
                SystemActionEngine.shared.refreshAccessibilityPermission(prompt: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                    showAccessibilityBanner = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .proCard(cornerRadius: 12, strokeColor: Color.orange.opacity(0.5))
    }
}
