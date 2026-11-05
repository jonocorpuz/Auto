import AppKit
import SwiftUI

/// Details of one shoot's mirror state: per-copy status, differences, notes and the sync actions.
struct ShootSyncPopover: View {
    @Environment(AppModel.self) private var model
    let item: ShootItem

    private var badge: SyncBadge { model.syncBadge(for: item.id) }

    /// The newest report we have: a finished check, or the size-pass report of a running one.
    private var report: ShootSyncReport? {
        switch model.syncStates[item.id] {
        case .done(let report, _)?: report
        case .checking(_, let partial)?: partial
        default: nil
        }
    }

    private var isBusy: Bool {
        switch badge {
        case .checking, .syncing: true
        default: false
        }
    }

    private var allOnline: Bool {
        !item.copies.isEmpty && item.copies.allSatisfy { $0.availability == .online }
    }

    private var canSync: Bool {
        guard case .outOfSync(let missing, _) = badge, missing > 0, allOnline, !isBusy else { return false }
        if case .done(let r, _)? = model.syncStates[item.id] { return r.depth == .checksums && r.notChecked == nil }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(item.copies) { copyRow($0) }
            }
            conflictsSection
            notesSection
            progressSection
            Divider()
            footer
            if let status = statusLine {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        switch badge {
        case .inSync:
            headerLabel("All copies match", "checkmark.seal.fill", Theme.success)
        case .outOfSync:
            headerLabel("Copies don't match", "exclamationmark.triangle.fill", Theme.warning)
        case .unknown(let reason):
            headerLabel(reason, "questionmark.circle", .secondary)
        case .checking:
            headerLabel("Checking copies…", "arrow.triangle.2.circlepath", .secondary)
        case .syncing:
            headerLabel("Syncing copies…", "arrow.triangle.2.circlepath", Theme.accent)
        case .none:
            headerLabel("Only one copy", "doc", .secondary)
        }
    }

    private func headerLabel(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(text).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    // MARK: Copies

    private func copyRow(_ copy: ShootCopyState) -> some View {
        let missing = missingFiles(for: copy)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(dotColor(copy.availability)).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(copy.volumeName + (copy.isPrimary ? " (main)" : ""))
                    .font(.system(size: 12, weight: .medium))
                Text(statusText(copy.availability, missing: missing))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show in Finder") {
                model.revealInFinder([URL(fileURLWithPath: copy.path, isDirectory: true)])
            }
            .buttonStyle(.borderless).controlSize(.small).foregroundStyle(Theme.accent)
            .disabled(copy.availability != .online && !isSameVolume(copy.availability))
        }
    }

    private func isSameVolume(_ a: CopyAvailability) -> Bool {
        if case .sameVolume = a { return true }
        return false
    }

    private func dotColor(_ a: CopyAvailability) -> Color {
        switch a {
        case .online: Theme.success
        case .offline: .secondary
        case .missing, .mismatch: .red
        case .sameVolume: Theme.warning
        }
    }

    private func statusText(_ a: CopyAvailability, missing: [SyncMissing]) -> String {
        switch a {
        case .offline: return "Drive not connected"
        case .missing: return "Folder not found"
        case .mismatch: return "Folder belongs to a different shoot"
        case .sameVolume(let name): return "Same drive as \(name), not a real backup"
        case .online:
            guard !missing.isEmpty else { return "Online" }
            let bytes = missing.reduce(Int64(0)) { $0 + $1.file.size }
            let size = bytes.formatted(.byteCount(style: .file))
            return "\(missing.count) \(missing.count == 1 ? "file" : "files") missing (\(size))"
        }
    }

    private func missingFiles(for copy: ShootCopyState) -> [SyncMissing] {
        guard let report else { return [] }
        let key = URL(fileURLWithPath: copy.path).standardizedFileURL.path
        return report.missing.first { $0.key.standardizedFileURL.path == key }?.value ?? []
    }

    // MARK: Conflicts, notes, progress

    @ViewBuilder private var conflictsSection: some View {
        if let conflicts = report?.conflicts, !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text("\(conflicts.count) \(conflicts.count == 1 ? "file differs" : "files differ") between copies. Auto won't change them.")
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(conflicts.enumerated()), id: \.offset) { _, c in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.relPath).font(.caption).lineLimit(1).truncationMode(.middle)
                                Text(describe(c.kind)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .help(c.relPath)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
        }
    }

    private func describe(_ kind: SyncConflict.Kind) -> String {
        switch kind {
        case .size: "Different sizes"
        case .content: "Same size, different contents"
        case .caseCollision: "Names differ only by capital letters"
        case .unreadable(let message): "Couldn't be read: \(message)"
        case .nestedShootMismatch: "A shoot folder on one copy, a plain folder on another"
        case .typeMismatch: "A file on one copy, a folder or link on another"
        }
    }

    @ViewBuilder private var notesSection: some View {
        let note = model.syncNotes[item.id]
        let error: String? = {
            if case .failed(let m)? = model.syncStates[item.id] { return m }
            return nil
        }()
        if note != nil || error != nil {
            VStack(alignment: .leading, spacing: 3) {
                Divider()
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var progressSection: some View {
        if case .checking(let p, _)? = model.syncStates[item.id] {
            progressBar(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : nil,
                        label: p.phase == .listing ? "Listing files…" : "Comparing \(p.filesDone) of \(p.filesTotal) files")
        } else if case .syncing(let p)? = model.syncStates[item.id] {
            progressBar(fraction: p.bytesTotal > 0 ? p.fraction : nil,
                        label: "Copying \(p.filesDone) of \(p.filesTotal) files")
        }
    }

    @ViewBuilder
    private func progressBar(fraction: Double?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Check Again") {
                let deep = NSEvent.modifierFlags.contains(.option)
                model.checkSync(shootID: item.id, deep: deep)
            }
            .help("Compare the copies again. Hold Option to re-read every file.")
            .disabled(isBusy)
            Button("Verify Contents") { model.checkSync(shootID: item.id, deep: true) }
                .help("Re-read every file on every copy and compare checksums.")
                .disabled(isBusy)
            Spacer()
            if isBusy {
                Button("Stop") { model.stopSync(shootID: item.id) }
            } else {
                Button("Sync Now") { model.syncNow(shootID: item.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSync)
                    .help(canSync ? "Copy missing files between the copies. Nothing is overwritten or deleted."
                                  : "Available when files are missing and every copy is connected.")
            }
        }
        .controlSize(.small)
    }

    private var statusLine: String? {
        var parts: [String] = []
        if case .done(_, let at)? = model.syncStates[item.id] {
            parts.append("Last checked \(at.formatted(.relative(presentation: .named)))")
        }
        if let deep = model.lastDeepVerify[item.id] {
            parts.append("Contents verified \(deep.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
