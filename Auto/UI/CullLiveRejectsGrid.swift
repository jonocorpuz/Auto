import SwiftUI
import AppKit

/// Rejects found by a cull, newest first, with a tag-count summary. Shown while running and kept for review.
struct CullLiveRejectsGrid: View {
    let rejects: [CullLiveReject]
    let running: Bool
    let applied: Bool

    private var header: String {
        if running { return "Rejected so far · \(rejects.count)" }
        return applied ? "Rejected · \(rejects.count)" : "Rejected · \(rejects.count) · Not applied"
    }

    private var tagCounts: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in rejects { counts[r.label, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (label: $0.key, count: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(header).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(tagCounts, id: \.label) { tag in
                    Text("\(tag.label) \(tag.count)")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.surfaceMuted, in: Capsule())
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(rejects.reversed()) { RejectTile(reject: $0) }
                }
            }
        }
    }
}

private struct RejectTile: View {
    let reject: CullLiveReject
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.rowRadius)
            .fill(Theme.surfaceMuted)
            .aspectRatio(1.5, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            .overlay(alignment: .bottomLeading) {
                Text(reject.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(6)
            }
            .help(reject.reason)
            .task(id: reject.id) {
                if image == nil, let data = reject.thumbnailJPEG { image = NSImage(data: data) }
            }
    }
}
