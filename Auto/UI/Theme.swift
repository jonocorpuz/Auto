import AppKit
import SwiftUI

/// Design tokens for the main window. Every color adapts to light and dark mode.
enum Theme {
    /// Window backdrop behind the sidebar and the content panel.
    static let canvas = Color(light: 0xF2F3F5, dark: 0x111214)
    /// The floating content panel.
    static let panel = Color(light: 0xFAFBFC, dark: 0x16171A)
    /// Cards inside the panel.
    static let surface = Color(light: 0xFFFFFF, dark: 0x1B1C1F)
    /// Subtle fill for rows, chips and inputs on a surface.
    static let surfaceMuted = Color(light: 0xF5F6F8, dark: 0x24262A)
    /// Selected sidebar row.
    static let selection = Color(light: 0xFFFFFF, dark: 0x26282C)
    static let border = Color(light: 0xE4E6EA, dark: 0x2E3035)
    static let accent = Color(light: 0x1D8CF0, dark: 0x3A9BF5)
    /// Backed-up / in-sync green (the same green as the menu bar's backed state).
    static let success = Color(nsColor: .systemGreen)
    /// Copies don't match.
    static let warning = Color(nsColor: .systemYellow)

    static let panelRadius: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let rowRadius: CGFloat = 10
}

extension Color {
    /// A color that resolves per appearance, from 0xRRGGBB values.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A rounded, bordered surface. The base container for content in the main window.
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }
}

/// Section title with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.title = title
        self.accessory = EmptyView()
    }
}

/// The large blue pill used for the primary action (Ingest).
struct PrimaryPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Capsule().fill(Theme.accent.opacity(isEnabled ? 1 : 0.45)))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
