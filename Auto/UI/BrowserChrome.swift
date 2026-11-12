import SwiftUI

// Pieces shared by the card browser and the shoot browser, so the two look and behave alike.

/// How a browser lays out its files. The raw values are stored in user defaults: don't rename them.
enum BrowserViewMode: String {
    case icons
    case list
}

/// Sizes of the icon grid shared by both browsers.
enum BrowserGrid {
    static let defaultIconSize = 110.0
    static let iconSizeRange = 72.0...200.0
    /// Gap between neighbouring cells.
    static let spacing = 6.0
    /// Gap between rows of cells.
    static let rowSpacing = 10.0
    /// The grid's assumed width until it has been measured.
    static let initialWidth = 600.0
    /// A cell is this much wider than its thumbnail, to leave room for the selection highlight.
    private static let cellPadding = 16.0

    static func cellWidth(iconSize: Double) -> Double {
        iconSize + cellPadding
    }

    static func columns(iconSize: Double) -> [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth(iconSize: iconSize)), spacing: spacing)]
    }

    /// How many columns the grid above ends up with, for arrow-key movement.
    /// `gridWidth` is the grid's own width, with its horizontal padding already excluded.
    static func columnCount(gridWidth: Double, iconSize: Double) -> Int {
        GridLayout<Int>.columnCount(width: gridWidth, itemMinimum: cellWidth(iconSize: iconSize),
                                    spacing: spacing, padding: 0)
    }
}

// MARK: - Toolbar

/// The chevron that leaves a browser and returns to the Media tab.
struct BrowserBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.borderless)
        .help("Back to Media")
        .keyboardShortcut("[", modifiers: .command)
    }
}

/// The eye button. Space toggles the Quick Look panel.
struct BrowserQuickLookButton: View {
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye")
        }
        .buttonStyle(.borderless)
        .help("Quick Look (Space)")
        .keyboardShortcut(.space, modifiers: [])
        .disabled(isDisabled)
    }
}

/// Icon size slider (icon view only) and the icons/list switch.
struct BrowserViewControls: View {
    @Binding var mode: BrowserViewMode
    @Binding var iconSize: Double

    var body: some View {
        if mode == .icons {
            Slider(value: $iconSize, in: BrowserGrid.iconSizeRange)
                .controlSize(.mini)
                .frame(width: 90)
                .help("Icon size")
        }
        Picker("View", selection: $mode) {
            Image(systemName: "square.grid.2x2").tag(BrowserViewMode.icons).help("Icons")
            Image(systemName: "list.bullet").tag(BrowserViewMode.list).help("List")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Status bar

/// The one-line summary under a browser's files.
struct BrowserStatusBar: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Theme.surface)
    }

    /// "12 items · 3.4 GB", or "2 of 12 items · 3.4 GB selected".
    static func summary(itemCount: Int, bytes: Int64, selectedCount: Int) -> String {
        let total = "\(Format.count(itemCount, "item", "items")) · \(Format.bytes(bytes))"
        if selectedCount == 0 { return total }
        return "\(selectedCount) of \(total) selected"
    }
}

// MARK: - Icon cell

/// One file or folder in icon view: a thumbnail over its name, like Finder.
struct BrowserIconCell<Thumbnail: View>: View {
    let name: String
    let size: Double
    let selected: Bool
    @ViewBuilder var thumbnail: Thumbnail

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                thumbnail
            }
            .frame(width: size, height: size * 0.75)
            .padding(6)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))

            Text(name)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(selected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: BrowserGrid.cellWidth(iconSize: size))
        .contentShape(Rectangle())
    }
}

/// A loaded thumbnail inside a `BrowserIconCell`.
struct BrowserThumbnail: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
    }
}

/// The SF Symbol shown inside a `BrowserIconCell` until (or instead of) a thumbnail.
struct BrowserPlaceholderSymbol: View {
    let symbol: String
    let size: Double

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.3, weight: .light))
    }
}

// MARK: - Keyboard

extension View {
    /// A key equivalent that works even when nothing in the browser has focus: an invisible button
    /// behind the view carries the shortcut.
    func hiddenShortcut(_ shortcut: KeyboardShortcut, action: @escaping () -> Void) -> some View {
        background {
            Button("", action: action)
                .keyboardShortcut(shortcut)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

extension KeyPress {
    /// Option/Control arrows mean something else to the system; the browsers leave them alone.
    var hasOptionOrControl: Bool {
        modifiers.contains(.option) || modifiers.contains(.control)
    }

    /// The grid movement an arrow, Home or End key asks for; nil for any other key.
    func gridDirection<ID: Hashable>() -> GridSelection<ID>.Direction? {
        switch key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        case .downArrow: .down
        case .home: .home
        case .end: .end
        default: nil
        }
    }
}

// MARK: - Media kinds

nonisolated extension MediaKind {
    /// SF Symbol for a file of this kind.
    var symbol: String {
        switch self {
        case .video: "film"
        case .photo: "photo"
        case .audio: "waveform"
        }
    }

    var displayName: String {
        switch self {
        case .video: "Video"
        case .photo: "Photo"
        case .audio: "Audio"
        }
    }
}

nonisolated enum BrowserKindLabel {
    /// "MOV Video", or just "Video" for a file with no extension.
    static func text(for url: URL, kindName: String) -> String {
        let fileExtension = url.pathExtension.uppercased()
        return fileExtension.isEmpty ? kindName : "\(fileExtension) \(kindName)"
    }
}
