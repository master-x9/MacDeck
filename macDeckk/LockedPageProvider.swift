//
//  LockedPageProvider.swift
//  MacDeck (macOS Host)
//
//  Defines the fixed tile layout shown on the phone while the Mac's
//  screen is locked: brightness, volume, keyboard brightness, play/pause,
//  and the Unlock Mac tile. This is a static page (not user-editable,
//  not shown in the sidebar) — DeckNetworkManager tells the phone to
//  switch to it on lock and away from it on unlock.
//

import Foundation
import AppKit

enum LockedPageProvider {

    /// Stable, well-known ID so the phone and Mac always agree on which
    /// page this is, the same way RunningAppsMonitor/BrowserMonitor do.
    static let lockedPageID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    
    private static func createTile(slotIndex: Int, action: SystemControlAction) -> DeckTile {
        // Render the Mac-specific SF Symbol into a PNG so the phone doesn't fall back to its generic icons
        let iconData = NSImage.sfSymbolPNGData(named: action.defaultSystemImageName, pointSize: 110, weight: .light)
        return DeckTile(slotIndex: slotIndex, tileType: .systemControl(action: action), iconData: iconData)
    }

    /// Slot layout (0-indexed):
    ///   0: Brightness up     1: Sleep Mac
    ///   2: Unlock Mac        3: Keep Awake
    ///   4: Volume up         5: Brightness down
    ///   6: Previous track    7: Play/Pause
    ///   8: Next track        9: Volume down
    static let lockedPage: DeckPage = {
        var tiles: [DeckTile?] = Array(repeating: nil, count: DeckPage.slotCount)
        tiles[0] = createTile(slotIndex: 0, action: .brightnessUp)
        tiles[1] = createTile(slotIndex: 1, action: .sleepMac)
        tiles[2] = createTile(slotIndex: 2, action: .unlockMac)
        tiles[3] = createTile(slotIndex: 3, action: .keepAwake)
        tiles[4] = createTile(slotIndex: 4, action: .volumeUp)
        tiles[5] = createTile(slotIndex: 5, action: .brightnessDown)
        tiles[6] = createTile(slotIndex: 6, action: .previousTrack)
        tiles[7] = createTile(slotIndex: 7, action: .playPause)
        tiles[8] = createTile(slotIndex: 8, action: .nextTrack)
        tiles[9] = createTile(slotIndex: 9, action: .volumeDown)
        return DeckPage(id: lockedPageID, name: "Locked", pageNumber: -1, tiles: tiles)
    }()
}
