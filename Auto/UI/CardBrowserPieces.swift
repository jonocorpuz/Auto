import SwiftUI

// The small views the card browser is built from.

/// Context menu content for one icon. A separate view so its body (selected files, shoot membership)
/// runs only when the menu opens.
struct LazyFileMenu: View {
    let owner: CardBrowserView
    let file: MediaFile
    let groups: [CardBrowser.Group]

    var body: some View {
        owner.fileMenu(owner.targets(for: file, in: groups), groups: groups)
    }
}

/// One row of the locations sidebar: a place on the card and how many files it holds.
struct LocationRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let count: Int
    /// The shoot's membership check is still running.
    var checking = false
    /// Why the shoot's membership check failed, if it did.
    var failure: String?

    var body: some View {
        HStack {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            Spacer()
            if checking {
                ProgressView().controlSize(.mini)
            } else if let failure {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .help("Couldn't check this shoot: \(failure)")
            }
            Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// The pinned header above each group of icons.
struct GroupHeader: View {
    let group: CardBrowser.Group

    var body: some View {
        HStack(spacing: 6) {
            if group.kind == .notBackedUp {
                StatusDot(color: Color(nsColor: AppModel.Status.unbacked.tint))
            } else {
                Image(systemName: group.kind.backedUpSymbol)
                    .foregroundStyle(Theme.accent)
            }
            Text(group.title).font(.system(size: 12, weight: .semibold))
            Text("\(group.files.count) · \(Format.bytes(group.bytes))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Theme.surface.opacity(0.95))
    }
}

/// One file in icon view: thumbnail over a (selectable) name, like Finder.
struct FileIcon: View {
    @Environment(AppModel.self) private var model
    let file: MediaFile
    let size: Double
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        BrowserIconCell(name: file.name, size: size, selected: selected) {
            if let image {
                BrowserThumbnail(image: image)
            } else {
                BrowserPlaceholderSymbol(symbol: file.kind.symbol, size: size)
                    .foregroundStyle(.tertiary)
            }
            if file.kind == .video, image != nil {
                playBadge
            }
        }
        .help(tooltip)
        .task(id: file.identity) {
            image = await model.fileThumbnail(for: file)
        }
    }

    /// Marks a video's thumbnail, bottom-left.
    private var playBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 10))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.45), in: Circle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(4)
    }

    private var tooltip: String {
        let recorded = file.date.formatted(date: .abbreviated, time: .shortened)
        return "\(file.name) · \(Format.bytes(file.size)) · \(recorded)"
    }
}
