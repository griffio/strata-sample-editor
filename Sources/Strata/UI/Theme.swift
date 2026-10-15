import SwiftUI
import AppKit

/// Strata's visual language: deep graphite surfaces, crisp hairlines and saturated,
/// luminous track colours that read well on dark backgrounds.
enum Theme {
    // Surfaces (darkest → lightest)
    static let base = Color(hex: 0x0D0E11)
    static let panel = Color(hex: 0x15171B)
    static let panelRaised = Color(hex: 0x1B1D22)
    static let control = Color(hex: 0x24272E)
    static let controlHover = Color(hex: 0x2C3038)
    static let hairline = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.12)

    // Text
    static let text = Color(hex: 0xECEDEF)
    static let textSecondary = Color(hex: 0x9A9EA8)
    static let textTertiary = Color(hex: 0x5F636D)

    // Accents
    static let accent = Color(hex: 0x4FD1FF)
    static let loop = Color(hex: 0xFFB648)
    static let record = Color(hex: 0xFF3D4F)
    static let solo = Color(hex: 0xFFD23F)
    static let mute = Color(hex: 0x7E8696)
    static let playhead = Color.white

    static let trackColorHex: [UInt32] = [
        0xFF6B6B, // coral
        0xFF9F45, // tangerine
        0xFFD25A, // amber
        0x9BE564, // lime
        0x2FE0B0, // mint
        0x3FD0FF, // cyan
        0x5C8DFF, // azure
        0xA47BFF, // violet
        0xEE6BFF, // orchid
        0xFF6FAE, // rose
    ]

    static let trackColors: [Color] = trackColorHex.map { Color(hex: $0) }

    static func trackColor(_ i: Int) -> Color { trackColors[((i % trackColors.count) + trackColors.count) % trackColors.count] }
    static func trackNSColor(_ i: Int) -> NSColor { NSColor(hex: trackColorHex[((i % trackColorHex.count) + trackColorHex.count) % trackColorHex.count]) }

    static let colorNames = ["Coral", "Tangerine", "Amber", "Lime", "Mint", "Cyan", "Azure", "Violet", "Orchid", "Rose"]

    // NSColor mirrors for AppKit drawing
    enum NS {
        static let base = NSColor(hex: 0x0D0E11)
        static let lane = NSColor(hex: 0x16181C)
        static let laneAlt = NSColor(hex: 0x181A1F)
        static let gridBar = NSColor.white.withAlphaComponent(0.10)
        static let gridBeat = NSColor.white.withAlphaComponent(0.045)
        static let gridSub = NSColor.white.withAlphaComponent(0.022)
        static let hairline = NSColor.white.withAlphaComponent(0.07)
        static let text = NSColor(hex: 0xECEDEF)
        static let textSecondary = NSColor(hex: 0x9A9EA8)
        static let textTertiary = NSColor(hex: 0x5F636D)
        static let loop = NSColor(hex: 0xFFB648)
        static let accent = NSColor(hex: 0x4FD1FF)
        static let record = NSColor(hex: 0xFF3D4F)
        static let selection = NSColor(hex: 0x4FD1FF)
    }

    static let headerWidth: CGFloat = 228
    static let rulerHeight: CGFloat = 34
    static let sidebarWidth: CGFloat = 272

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func label(_ size: CGFloat = 11, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    func blended(_ t: CGFloat, with other: NSColor) -> NSColor {
        blended(withFraction: t, of: other) ?? self
    }
}

/// Small uppercase section caption used throughout the panels.
struct SectionCaption: View {
    let text: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold))
                .kerning(0.9)
                .foregroundColor(Theme.textTertiary)
            Spacer(minLength: 0)
            if let t = trailing { t }
        }
    }
}

/// Icon button with hover feedback, used in toolbars and panels.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var active: Bool = false
    var activeColor: Color = Theme.accent
    var size: CGFloat = 13
    var width: CGFloat = 28
    var height: CGFloat = 24
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(disabled ? Theme.textTertiary.opacity(0.6) : (active ? activeColor : (hover ? Theme.text : Theme.textSecondary)))
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? activeColor.opacity(0.16) : (hover && !disabled ? Color.white.opacity(0.07) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Compact pill toggle (M / S / R style).
struct PillToggle: View {
    let label: String
    let on: Bool
    let color: Color
    var help: String = ""
    var symbol: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Group {
                if let s = symbol {
                    Image(systemName: s).font(.system(size: 9, weight: .heavy))
                } else {
                    Text(label).font(.system(size: 10, weight: .heavy, design: .rounded))
                }
            }
            .foregroundColor(on ? Color.black.opacity(0.85) : (hover ? Theme.text : Theme.textSecondary))
            .frame(width: 22, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(on ? color : Color.white.opacity(hover ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(on ? color.opacity(0.0) : Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: on ? color.opacity(0.55) : .clear, radius: 5)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// A raised, rounded panel container.
struct PanelBackground: View {
    var radius: CGFloat = 10
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.panelRaised)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
