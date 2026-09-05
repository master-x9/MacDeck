//
//  MacDeckApp.swift
//  MacDeck (macOS Host)
//
//  App entry point. Owns PageStore and DeckNetworkManager as @StateObject,
//  wires the page provider, manages lifecycle (start/stop network, release
//  Keep Awake assertion on quit), and injects environment objects.
//

import SwiftUI
import AppKit

@main
struct MacDeckApp: App {
    // Shared state objects
    @StateObject private var store = PageStore()
    @StateObject private var network = DeckNetworkManager()
    @State private var menuBarController: MenuBarController? = nil
    
    @State private var isInitialized = false

    var body: some Scene {
        WindowGroup("MacDeck") {
            ContentView()
                .environmentObject(store)
                .environmentObject(network)
#if os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    if SystemActionEngine.shared.isKeepAwakeActive {
                        SystemActionEngine.shared.execute(.systemControl(action: .keepAwake))
                    }
                    network.stop()
                }
#endif
                .onAppear {
                    guard !isInitialized else { return }
                    isInitialized = true
                    
                    network.pagesProvider = { [weak store] in
                        store?.allPages ?? []
                    }
                    network.start()
                    self.menuBarController = MenuBarController(pageStore: store, deckNetworkManager: network)
                }
        }
        // Set a comfortable default size for the sidebar + detail layout
        .defaultSize(width: 900, height: 650)
        .commands {
            // Include standard sidebar commands
            SidebarCommands()
        }
    }
}
