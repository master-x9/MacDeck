//
//  LaunchAtLoginManager.swift
//  MacDeck (macOS Host)
//
//  Manages Start at Login / Launch at Login via macOS ServiceManagement SMAppService.
//

import Foundation
import ServiceManagement
import Combine

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool = false

    private init() {
        refreshStatus()
    }

    /// Queries the current SMAppService status from the system
    func refreshStatus() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            self.isEnabled = (status == .enabled)
        } else {
            self.isEnabled = false
        }
    }

    /// Enables or disables start at login using SMAppService
    func setEnabled(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                NSLog("MacDeck LaunchAtLoginManager: Failed to update start at login (\(enable)): \(error.localizedDescription)")
            }
            refreshStatus()
        }
    }

    /// Toggles the start at login state
    func toggle() {
        setEnabled(!isEnabled)
    }
}
