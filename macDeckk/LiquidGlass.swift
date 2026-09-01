//
//  LiquidGlass.swift
//  MacDeck (macOS Host)
//
//  Professional design tokens, tactile keycap shaders, and refined glass materials.
//

import SwiftUI
import AppKit

extension View {

    /// Professional surface container with subtle glass depth, hairline stroke, and soft shadow
    @ViewBuilder
    func proCard(
        cornerRadius: CGFloat = 16,
        fillColor: Color = Color.black.opacity(0.25),
        strokeColor: Color = Color.white.opacity(0.1),
        shadowRadius: CGFloat = 8,
        shadowY: CGFloat = 4
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [strokeColor, strokeColor.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.25), radius: shadowRadius, x: 0, y: shadowY)
    }

    /// The standard glass card treatment
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill((tint ?? Color.black).opacity(0.2))
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                (tint ?? Color.white).opacity(0.2),
                                (tint ?? Color.white).opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
    }

    @ViewBuilder
    func keycapSurface(
        isHovered: Bool = false,
        isTargeted: Bool = false,
        isSelected: Bool = false,
        isControl: Bool = false,
        cornerRadius: CGFloat = 16
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isTargeted ?
                        Color.accentColor.opacity(0.25) :
                        (isHovered ?
                         (isControl ? Color(white: 0.20) : Color(white: 0.16)) :
                         (isControl ? Color(white: 0.14) : Color(white: 0.11)))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isTargeted ? Color.accentColor : (isHovered || isSelected ? Color.white.opacity(0.35) : Color.white.opacity(0.12)),
                        lineWidth: isTargeted ? 2.0 : (isSelected ? 1.5 : 1.0)
                    )
            )
            .shadow(
                color: isTargeted ? Color.accentColor.opacity(0.5) : (isHovered ? Color.black.opacity(0.35) : Color.clear),
                radius: isTargeted ? 8 : (isHovered ? 4 : 0),
                x: 0,
                y: isHovered ? 2 : 0
            )
    }

    /// A glass pill, for compact status indicators (StatusPillView).
    @ViewBuilder
    func glassPill(tint: Color? = nil) -> some View {
        self
            .background(
                Capsule()
                    .fill((tint ?? Color.black).opacity(0.2))
                    .background(Capsule().fill(.ultraThinMaterial))
            )
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                (tint ?? Color.white).opacity(0.3),
                                (tint ?? Color.white).opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
    }

    /// Mac keyboard keycap badge style (e.g. for shortcut keys or control symbols)
    @ViewBuilder
    func macKeycapBadge() -> some View {
        self
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 2, y: 1)
    }
}
