import SwiftUI

/// Media tab: connected cards, recent shoots and drives.
struct MediaView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.workRoot == nil {
            ContentUnavailableView {
                Label("Where do shoots go?", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Pick the folder your shoots live in on your working drive.")
            } actions: {
                Button("Choose Work Folder…") { model.setWorkRoot() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    stats
                    cardsSection
                    shootsSection
                    drivesSection
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Stats

    private var stats: some View {
        HStack(spacing: 12) {
            StatTile(title: "Cards connected", value: "\(model.cards.count)", symbol: "sdcard")
            StatTile(title: "Need backup", value: "\(needsBackupCount)", symbol: "exclamationmark.arrow.triangle.2.circlepath",
                     tint: needsBackupCount > 0 ? Color(nsColor: AppModel.Status.unbacked.tint) : nil)
            StatTile(title: "Drives", value: "\(model.drives.count)", symbol: "externaldrive")
        }
    }

    private var needsBackupCount: Int {
        model.cards.filter { $0.phase == .needsBackup || $0.phase == .ready }.count
    }

    // MARK: Cards

    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Cards")
            if model.cards.isEmpty {
                SurfaceCard(padding: 32) {
                    VStack(spacing: 8) {
                        Image(systemName: "sdcard")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No cards connected").font(.system(size: 14, weight: .semibold))
                        Text("Connect a camera card and Auto checks it against \(model.workingDriveName).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(model.cards) { card in CardRow(card: card) }
            }
        }
    }

    // MARK: Shoots (placeholder)

    private var shootsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recent shoots") {
                Text("Coming soon").font(.caption).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in ShootPlaceholderTile() }
            }
        }
    }

    // MARK: Drives

    @ViewBuilder private var drivesSection: some View {
        if !model.drives.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Drives")
                SurfaceCard(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.drives.enumerated()), id: \.element.id) { index, drive in
                            if index > 0 { Divider().padding(.leading, 44) }
                            HStack(spacing: 12) {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                Text(drive.name).font(.system(size: 13, weight: .medium))
                                Spacer()
                                if drive.url == model.workingVolume {
                                    Text("Working drive")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Theme.accent.opacity(0.12), in: Capsule())
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color?

    var body: some View {
        SurfaceCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint ?? .primary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(tint ?? .secondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// Stand-in tile until shoots are listed from the work folder.
private struct ShootPlaceholderTile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surfaceMuted)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(Image(systemName: "film.stack").font(.title2).foregroundStyle(.quaternary))
            RoundedRectangle(cornerRadius: 3).fill(Theme.surfaceMuted).frame(width: 110, height: 9)
            RoundedRectangle(cornerRadius: 3).fill(Theme.surfaceMuted).frame(width: 70, height: 7)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }
}
