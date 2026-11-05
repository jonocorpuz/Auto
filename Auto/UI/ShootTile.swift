import SwiftUI

/// One shoot in the Shoots grid: preview, name, date, counts and quick actions.
struct ShootTile: View {
    @Environment(AppModel.self) private var model
    let item: ShootItem
    @State private var showSync = false
    @State private var copyToRemove: ShootCopyState?

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
            Button("Add Mirror…") { model.addMirror(shootID: item.id) }
            Button("Check Sync") { model.checkSync(shootID: item.id) }
                .disabled(item.copies.count < 2)
            Button("Sync Now") { model.syncNow(shootID: item.id) }
                .disabled(item.copies.count < 2)
            if !item.copies.isEmpty {
                Menu("Copies") {
                    ForEach(item.copies) { copy in
                        Menu(copy.volumeName + (copy.isPrimary ? " (main)" : "")) {
                            Button("Show in Finder") {
                                model.revealInFinder([URL(fileURLWithPath: copy.path, isDirectory: true)])
                            }
                            if copy.availability == .missing || copy.availability == .mismatch {
                                Button("Locate…") { model.locateCopy(shootID: item.id, path: copy.path) }
                            }
                            Divider()
                            Button("Remove Copy from Auto…") { copyToRemove = copy }
                        }
                    }
                }
            }
            Divider()
            Button("Remove from Auto") { Task { await model.forgetShoot(id: item.id) } }
                .help("Removes the shoot from Auto's list. Files on disk are not deleted.")
        }
        .alert("Remove this copy from Auto?", isPresented: removeAlertShown, presenting: copyToRemove) { copy in
            Button("Remove Copy", role: .destructive) {
                Task { try? await model.removeCopy(shootID: item.id, path: copy.path) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { copy in
            Text("\(copy.path) will no longer be tracked as a copy of this shoot. Files on disk are not deleted.")
        }
    }

    private var removeAlertShown: Binding<Bool> {
        Binding(get: { copyToRemove != nil }, set: { if !$0 { copyToRemove = nil } })
    }

    // MARK: Sync badge

    @ViewBuilder private var syncBadgeView: some View {
        let badge = model.syncBadge(for: item.id)
        if badge != .none {
            Button { showSync = true } label: {
                badgeIcon(badge)
                    .padding(5)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .help(badgeHelp(badge))
            .accessibilityLabel(badgeAccessibility(badge))
            .popover(isPresented: $showSync, arrowEdge: .bottom) {
                ShootSyncPopover(item: item)
            }
        }
    }

    @ViewBuilder private func badgeIcon(_ badge: SyncBadge) -> some View {
        switch badge {
        case .inSync:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success)
        case .outOfSync:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        case .unknown:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .checking, .syncing:
            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        case .none:
            EmptyView()
        }
    }

    private func badgeHelp(_ badge: SyncBadge) -> String {
        switch badge {
        case .inSync(let copies, let checkedAt, let deep):
            var text = "All \(copies) copies match · checked \(checkedAt.formatted(.relative(presentation: .named)))"
            if let deep { text += "\nContents fully verified \(deep.formatted(date: .abbreviated, time: .omitted))" }
            return text
        case .outOfSync: return "Copies of this shoot don't match"
        case .unknown(let reason): return reason
        case .checking: return "Checking copies…"
        case .syncing: return "Syncing copies…"
        case .none: return ""
        }
    }

    private func badgeAccessibility(_ badge: SyncBadge) -> String {
        switch badge {
        case .inSync: "Copies in sync"
        case .outOfSync: "Copies out of sync"
        case .unknown(let reason): "Sync status unknown. \(reason)"
        case .checking: "Checking copies"
        case .syncing: "Syncing copies"
        case .none: ""
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
            .overlay(alignment: .topTrailing) { syncBadgeView }
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
