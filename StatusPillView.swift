//
//  StatusPillView.swift
//  MacDeck (macOS Host)
//
//  A compact status indicator displaying live connection state
//  with breathing glow dot and device status label.
//

import SwiftUI

struct StatusPillView: View {
    let status: DeckNetworkManager.ConnectionStatus

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(dotColor.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(isPulsing ? 1.4 : 0.8)
                    .opacity(isPulsing ? 1.0 : 0.0)
                    .animation(
                        isPulsing ?
                        .easeInOut(duration: 1.1).repeatForever(autoreverses: true) :
                        .default,
                        value: isPulsing
                    )

                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: dotColor.opacity(0.8), radius: 3)
            }

            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassPill(tint: dotColor)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: dotColor)
    }

    private var dotColor: Color {
        switch status {
        case .disconnected: return .red
        case .waiting, .awaitingApproval: return .orange
        case .awaitingHello, .connected: return .green
        }
    }

    private var isPulsing: Bool {
        switch status {
        case .waiting, .awaitingApproval: return true
        default: return false
        }
    }

    private var label: String {
        switch status {
        case .disconnected:
            return "Disconnected"
        case .waiting:
            return "Searching for Phone…"
        case .awaitingHello:
            return "Handshake…"
        case .awaitingApproval(_, let deviceName):
            return "Approve \(deviceName)"
        case .connected(let deviceName):
            return deviceName.isEmpty ? "Connected" : deviceName
        }
    }
}
