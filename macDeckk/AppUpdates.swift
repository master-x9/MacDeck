import AppKit
import Sparkle

/// Keep Sparkle's progress, cancellation and error UI. The first prompt explicitly
/// includes restart consent, so a completed download needs no second click.
@MainActor
final class UpdatePrompt: SPUStandardUserDriver {
    private var restartApproved = false

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let alert = NSAlert()
        alert.messageText = "MacDeck \(appcastItem.displayVersionString) is available"
        alert.informativeText = (appcastItem.itemDescription ?? "") + "\n\nMacDeck will download the update and restart."
        alert.addButton(withTitle: "Update & Restart")
        alert.addButton(withTitle: "Later")
        restartApproved = alert.runModal() == .alertFirstButtonReturn
        reply(restartApproved ? .install : .dismiss)
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if restartApproved {
            restartApproved = false
            reply(.install)
        } else {
            super.showReady(toInstallAndRelaunch: reply)
        }
    }
}

@MainActor
final class AppUpdates {
    static let shared = AppUpdates()
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: UpdatePrompt(hostBundle: .main, delegate: nil), delegate: nil)
    func start() {
        do { try updater.start() }
        catch { NSLog("Could not start MacDeck updates: %@", error.localizedDescription) }
    }
}
