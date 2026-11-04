import SwiftUI

/// One shoot in the Shoots grid: preview, name, date, counts and quick actions.
struct ShootTile: View {
    @Environment(AppModel.self) private var model
    let item: ShootItem

    private var isOnline: Bool {
        switch item.availability {
        case nil, .online: true
        default: false
        }
    }

    private var isOffline: Bool { item.availability == .offline }

    private var isMissing: Bool {
        switch item.availability {
        case .missing, .mismatch: true
        default: false
        }
    }

    private var canAdd: Bool {
        if case .online = item.availability { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                Text(item.record.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(item.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let counts = countsText {
                    Text(counts).font(.caption).foregroundStyle(.secondary)
                }
            }
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
        .opacity(isOnline ? 1 : 0.55)
        .contextMenu {
            Button("Add footage") { model.addFootage(to: item.id) }
                .disabled(!canAdd)
            Button("Locate…") { model.locateShoot(id: item.id) }
            Divider()
            Button("Remove from Auto") { Task { await model.forgetShoot(id: item.id) } }
                .help("Removes the shoot from Auto's list. Files on disk are not deleted.")
        }
    }

    private var preview: some View {
        Theme.surfaceMuted
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image = item.thumbnail {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film.stack").font(.title2).foregroundStyle(.quaternary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var footer: some View {
        if isOffline {
            Text("Drive not connected").font(.caption).foregroundStyle(.secondary)
        } else if isMissing {
            HStack {
                Text("Folder not found").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Locate…") { model.locateShoot(id: item.id) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Theme.accent)
            }
        } else {
            Button {
                model.addFootage(to: item.id)
            } label: {
                Label("Add footage", systemImage: "plus")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(Theme.accent)
            .disabled(!canAdd)
        }
    }

    private var countsText: String? {
        guard let summary = item.summary else { return nil }
        let v = summary.videoCount, p = summary.photoCount
        if v == 0 && p == 0 { return "Empty" }
        var parts: [String] = []
        if v > 0 { parts.append("\(v) \(v == 1 ? "video" : "videos")") }
        if p > 0 { parts.append("\(p) \(p == 1 ? "photo" : "photos")") }
        return parts.joined(separator: " · ")
    }
}
