import SwiftUI

// The small views the shoot browser is built from.

nonisolated extension ShootEntry {
    /// SF Symbol for this entry in a list or as an icon placeholder.
    var symbol: String {
        if isFolder { return "folder.fill" }
        return kind?.symbol ?? "doc"
    }

    /// "Folder", "MOV Video", or "PDF Document" for files Auto doesn't classify as media.
    var kindLabel: String {
        if isFolder { return "Folder" }
        return BrowserKindLabel.text(for: url, kindName: kind?.displayName ?? "Document")
    }
}

/// Makes a folder cell a drop target for Finder files, highlighted while a drag is over it.
struct FolderDrop: ViewModifier {
    let entry: ShootEntry
    /// The folder currently under the drag, shared so the browser can hide its own highlight.
    @Binding var hover: URL?
    let drop: ([URL]) -> Bool
    @State private var targeted = false

    func body(content: Content) -> some View {
        if entry.isFolder {
            content
                .background(targeted ? Theme.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { isTargeted in
                    targeted = isTargeted
                    updateHover(isTargeted: isTargeted)
                }
        } else {
            content
        }
    }

    private func updateHover(isTargeted: Bool) {
        if isTargeted {
            hover = entry.url
        } else if hover == entry.url {
            hover = nil
        }
    }
}

/// One file or folder in icon view: thumbnail over a name, like Finder.
struct EntryIcon: View {
    /// Longest side of the thumbnails requested for the grid.
    private static let thumbnailMaxPixels: CGFloat = 320

    @Environment(AppModel.self) private var model
    let entry: ShootEntry
    let size: Double
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        BrowserIconCell(name: entry.name, size: size, selected: selected) {
            if let image {
                BrowserThumbnail(image: image)
            } else {
                BrowserPlaceholderSymbol(symbol: entry.symbol, size: size)
                    .foregroundStyle(entry.isFolder ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            }
        }
        .help(tooltip)
        .task(id: entry.id) {
            await loadThumbnail()
        }
    }

    private var tooltip: String {
        let modified = entry.date.formatted(date: .abbreviated, time: .shortened)
        if entry.isFolder { return "\(entry.name) · \(modified)" }
        return "\(entry.name) · \(Format.bytes(entry.size)) · \(modified)"
    }

    /// Only media files get a thumbnail; folders and other documents keep their symbol.
    private func loadThumbnail() async {
        let isMediaFile = !entry.isFolder && entry.kind != nil
        guard isMediaFile else {
            image = nil
            return
        }
        image = try? await model.thumbnails.thumbnail(for: entry.url, maxPixels: Self.thumbnailMaxPixels)
    }
}
