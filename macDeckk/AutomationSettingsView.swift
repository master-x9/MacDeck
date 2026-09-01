//
//  AutomationSettingsView.swift
//  MacDeck (macOS Host)
//
//  Settings sheet for connecting OBS (obs-websocket) and Discord (bot
//  token), and for picking which Discord channels get pinned to the
//  auto-generated Discord page. Opened from SidebarBottomSection.
//

import SwiftUI

struct AutomationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var obs = OBSControlManager.shared
    @ObservedObject private var discord = DiscordControlManager.shared

    @State private var obsHost: String = OBSControlManager.shared.host
    @State private var obsPort: String = String(OBSControlManager.shared.port)
    @State private var obsPassword: String = ""
    @State private var obsHasPassword: Bool = OBSControlManager.shared.hasPassword()

    @State private var discordToken: String = ""
    @State private var discordHasToken: Bool = DiscordControlManager.shared.hasToken()

    @State private var selectedTab: Tab = .obs
    enum Tab { case obs, discord }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OBS & Discord")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Picker("", selection: $selectedTab) {
                Text("OBS").tag(Tab.obs)
                Text("Discord").tag(Tab.discord)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .labelsHidden()

            Divider()

            ScrollView {
                if selectedTab == .obs {
                    obsSettings
                } else {
                    discordSettings
                }
            }
        }
        .frame(width: 440, height: 520)
    }

    // MARK: - OBS

    private var obsSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connects to OBS's built-in WebSocket server. In OBS: Tools ▸ WebSocket Server Settings, turn it on, and copy the password here (leave blank if you turned authentication off).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Circle()
                    .fill(obs.isConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(obs.isConnected ? "Connected" : "Not connected")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }

            if let error = obs.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("HOST").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                TextField("127.0.0.1", text: $obsHost)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("PORT").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                TextField("4455", text: $obsPort)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("PASSWORD").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                SecureField(obsHasPassword ? "•••••••• (saved — leave blank to keep)" : "No password set", text: $obsPassword)
                    .textFieldStyle(.roundedBorder)
            }

            Button("Save & Reconnect") {
                obs.host = obsHost
                obs.port = Int(obsPort) ?? 4455
                if !obsPassword.isEmpty {
                    obs.setPassword(obsPassword)
                    obsHasPassword = true
                    obsPassword = ""
                } else {
                    obs.reconnect()
                }
            }
            .buttonStyle(.borderedProminent)

            if obs.isConnected && !obs.scenes.isEmpty {
                Divider()
                Text("SCENES").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                ForEach(obs.scenes, id: \.self) { scene in
                    HStack(spacing: 6) {
                        Image(systemName: scene == obs.currentScene ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(scene == obs.currentScene ? Color.accentColor : Color.secondary)
                        Text(scene).font(.system(size: 12))
                    }
                }
            }

            Text("The OBS page (Record, Stream, Replay Buffer, Mic, and one tile per scene) builds itself automatically once connected — nothing else to configure here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    // MARK: - Discord

    private var discordSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a bot at discord.com/developers/applications, enable “Message Content Intent” under the Bot tab, invite it to your own server(s), and paste its token below. MacDeck only ever talks to Discord as this bot — never as your personal account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("A bot can't see your personal DM list — Discord doesn't expose that to bots. \"Direct Messages\" below are DM channels the bot itself has been messaged in. \"New activity\" means the bot was @mentioned, or a pinned channel got a new message.")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Circle()
                    .fill(discord.isConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(discord.isConnected ? "Connected" : "Not connected")
                    .font(.system(size: 12, weight: .medium))
            }

            if let error = discord.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("BOT TOKEN").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                SecureField(discordHasToken ? "•••••••• (saved — leave blank to keep)" : "Paste bot token", text: $discordToken)
                    .textFieldStyle(.roundedBorder)
            }

            Button("Save & Connect") {
                guard !discordToken.isEmpty else { return }
                discord.setToken(discordToken)
                discordHasToken = true
                discordToken = ""
            }
            .buttonStyle(.borderedProminent)

            if discord.isConnected {
                Divider()
                Text("PIN CHANNELS TO YOUR DECK").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)

                if discord.availableGuilds.isEmpty && discord.availableDMChannels.isEmpty {
                    Text("Waiting for the bot's server list to sync…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                ForEach(discord.availableGuilds) { guild in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(guild.name)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.top, 6)
                        ForEach(guild.textChannels) { channel in
                            channelToggleRow(channel)
                        }
                    }
                }

                if !discord.availableDMChannels.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Direct Messages")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.top, 6)
                        ForEach(discord.availableDMChannels) { channel in
                            channelToggleRow(channel)
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    private func channelToggleRow(_ channel: DiscordChannelRef) -> some View {
        let isPinned = discord.pinnedChannels.contains(channel)
        return HStack(spacing: 6) {
            Image(systemName: channel.isDM ? "person.circle" : "number")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(channel.channelName)
                .font(.system(size: 12))
            Spacer()
            Button(isPinned ? "Pinned" : "Pin") {
                var updated = discord.pinnedChannels
                if isPinned {
                    updated.removeAll { $0 == channel }
                } else {
                    updated.append(channel)
                }
                discord.setPinnedChannels(updated)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(isPinned ? Color.accentColor : Color.secondary)
        }
    }
}
