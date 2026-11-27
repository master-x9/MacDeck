//
//  SidebarBottomSection.swift
//  MacDeck (macOS Host)
//
//  Sidebar settings & security drawer: toggles for running apps & browser control,
//  secure Keychain remote unlock setup, trusted devices manager, and developer footer.
//

import SwiftUI
import LocalAuthentication

struct SidebarBottomSection: View {
    @EnvironmentObject var store: PageStore
    @StateObject private var trustStore = TrustedDeviceStore.shared
    @ObservedObject private var remoteUnlock = RemoteUnlockManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var obsMonitor = OBSControlManager.shared
    @ObservedObject private var calls = DiscordCalls.shared
    @ObservedObject private var discordMonitor = DiscordControlManager.shared

    @State private var isTrustedExpanded = false
    @State private var showPasswordSheet = false
    @State private var passwordInput = ""
    @State private var passwordError: String? = nil
    @State private var isPasswordForEnabling = true
    @State private var showAutomationSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            Text("STREAM & SECURITY")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.secondary.opacity(0.8))
                .tracking(0.6)
                .padding(.horizontal, 4)

            // Dynamic Stream Switches
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(launchAtLogin.isEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    Text("Start at Login")
                        .font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { newValue in launchAtLogin.setEnabled(newValue) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                HStack {
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(store.showRunningAppsPage ? Color.green : Color.secondary)
                        .frame(width: 16)
                    Text("Running Apps Page")
                        .font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: $store.showRunningAppsPage)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }

                HStack {
                    Image(systemName: "safari")
                        .font(.system(size: 12))
                        .foregroundStyle(store.showBrowserControlPage ? Color.blue : Color.secondary)
                        .frame(width: 16)
                    Text("Browser Control")
                        .font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: $store.showBrowserControlPage)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }

                HStack {
                    Image(systemName: "lock.open.laptopcomputer")
                        .font(.system(size: 12))
                        .foregroundStyle(remoteUnlock.isEnabled ? Color.orange : Color.secondary)
                        .frame(width: 16)
                    Text("Unlock from Phone")
                        .font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { remoteUnlock.isEnabled },
                        set: { newValue in authenticateForToggle(newValue) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                HStack {
                    Image(systemName: "record.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(store.showOBSPage ? Color.red : Color.secondary)
                        .frame(width: 16)
                    Text("OBS Page")
                        .font(.system(size: 12))
                    Spacer()
                    if obsMonitor.isConnected {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                    }
                    Toggle("", isOn: $store.showOBSPage)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }

                HStack {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 12))
                        .foregroundStyle(store.showDiscordPage ? Color.indigo : Color.secondary)
                        .frame(width: 16)
                    Text("Discord Page")
                        .font(.system(size: 12))
                    Spacer()
                    if calls.page != nil || discordMonitor.isConnected {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                    }
                    Toggle("", isOn: $store.showDiscordPage)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                if store.showDiscordPage {
                    if calls.status == .needsAccessibility {
                        Button(calls.status.rawValue) {
                            SystemActionEngine.shared.refreshAccessibilityPermission(prompt: true)
                        }.font(.caption).buttonStyle(.link)
                    } else {
                        Text(calls.status.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )

            Button {
                showAutomationSettings = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 11))
                    Text("Configure OBS & Discord…")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            Link(destination: URL(string: "https://macdeck.fun/?support=1")!) {
                Label("Support MacDeck", systemImage: "heart")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 4)

            // Trusted Devices Disclosure
            DisclosureGroup(isExpanded: $isTrustedExpanded) {
                if trustStore.devices.isEmpty {
                    Text("No paired phones remembered.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 4) {
                        ForEach(trustStore.devices) { device in
                            HStack {
                                Image(systemName: "iphone")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(device.deviceName)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Button("Forget") {
                                    trustStore.forget(clientID: device.clientID)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.red.opacity(0.8))
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 12))
                    Text("Trusted Devices (\(trustStore.devices.count))")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.primary)
            }
            .padding(.horizontal, 4)

            Divider()
                .padding(.vertical, 2)

            // Footer Developer Credits
            HStack(spacing: 4) {
                Text("Crafted for macOS by")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: "https://github.com/master-x9") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Masterx-9")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("v1.0")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .sheet(isPresented: $showPasswordSheet) {
            remoteUnlockPasswordSheet
        }
        .sheet(isPresented: $showAutomationSettings) {
            AutomationSettingsView()
        }
    }

    // MARK: - Remote Unlock Password Sheet

    private var remoteUnlockPasswordSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.open.laptopcomputer")
                .font(.system(size: 32))
                .foregroundStyle(Color.orange)

            Text(isPasswordForEnabling ? "Enable Remote Unlock" : "Turn Off Remote Unlock")
                .font(.headline)

            Text(isPasswordForEnabling ?
                 "Your password is encrypted securely inside the macOS Keychain. It is used strictly locally when triggered by your paired phone." :
                 "Enter your Mac password to remove remote unlock credentials from Keychain."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 260)

            SecureField("Mac user password", text: $passwordInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { savePassword() }

            if let passwordError {
                Text(passwordError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    passwordInput = ""
                    showPasswordSheet = false
                }
                .buttonStyle(.bordered)

                Button(isPasswordForEnabling ? "Save to Keychain" : "Turn Off") {
                    savePassword()
                }
                .buttonStyle(.borderedProminent)
                .disabled(passwordInput.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    // MARK: - macOS Authentication

    private func authenticateForToggle(_ enable: Bool) {
        let context = LAContext()
        var authError: NSError?
        let reason = enable ? "Authenticate to enable Unlock from Phone" : "Authenticate to disable Unlock from Phone"

        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                DispatchQueue.main.async {
                    if success {
                        if enable {
                            self.passwordInput = ""
                            self.passwordError = nil
                            self.isPasswordForEnabling = true
                            self.showPasswordSheet = true
                        } else {
                            self.remoteUnlock.disable()
                        }
                    }
                }
            }
        } else {
            self.passwordInput = ""
            self.passwordError = nil
            self.isPasswordForEnabling = enable
            self.showPasswordSheet = true
        }
    }

    private func savePassword() {
        guard !passwordInput.isEmpty else { return }
        if isPasswordForEnabling {
            do {
                try remoteUnlock.enable(password: passwordInput)
                passwordInput = ""
                passwordError = nil
                showPasswordSheet = false
            } catch {
                passwordError = error.localizedDescription
            }
        } else {
            if remoteUnlock.verify(password: passwordInput) {
                remoteUnlock.disable()
                passwordInput = ""
                passwordError = nil
                showPasswordSheet = false
            } else {
                passwordError = "Incorrect password."
            }
        }
    }
}
