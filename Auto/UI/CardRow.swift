import SwiftUI

/// One connected card: name, cameras, counts, state and the actions for its phase.
struct CardRow: View {
    /// Day chips shown per camera before the rest collapse into "+N".
    private static let maxDayChips = 4
    /// Shoots from other days offered in the Add to Shoot menu.
    private static let maxOtherShootsInMenu = 10

    @Environment(AppModel.self) private var model
    let card: Card
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !card.cameras.isEmpty { cameraList }
            phaseContent
            notes
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(borderColor))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onTapGesture { if canBrowse { model.browsingCardID = card.id } }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var canBrowse: Bool { !card.files.isEmpty }

    private var isQueued: Bool { card.queuedBehind != nil }

    /// The border hints that the row is clickable while the pointer is over it.
    private var borderColor: Color {
        hovering && canBrowse ? Theme.accent.opacity(0.6) : Theme.border
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(color: Color(nsColor: status.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name).font(.headline)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(phaseLabel).font(.callout).foregroundStyle(.secondary)
            if canBrowse {
                Button { model.browsingCardID = card.id } label: {
                    Label("Browse", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Browse the files on this card")
            }
        }
    }

    /// The menu bar status this card's phase corresponds to; the dot uses its colour.
    private var status: AppModel.Status {
        switch card.phase {
        case .scanning, .verifying, .empty: .idle
        case .copying: .copying
        case .backed: .backed
        case .needsBackup, .ready: .unbacked
        case .failed, .unreadable: .error
        }
    }

    private var phaseLabel: String {
        switch card.phase {
        case .scanning: "Checking…"
        case .verifying: "Checking backup…"
        case .needsBackup: "Not backed up"
        case .ready: "Ready to copy"
        case .copying: "Copying…"
        case .backed: "Backed up"
        case .failed: "Failed"
        case .empty: "No media"
        case .unreadable: "Can't read"
        }
    }

    /// "12 video · 40 photo · 64 GB", plus how much is not backed up while that still matters.
    private var summary: String {
        guard !card.files.isEmpty else {
            return card.phase == .scanning ? "Counting files…" : "No photos or video on this card."
        }
        var parts: [String] = []
        if card.videoCount > 0 { parts.append("\(card.videoCount) video") }
        if card.photoCount > 0 { parts.append("\(card.photoCount) photo") }
        parts.append(Format.bytes(card.totalBytes))
        if let backupSummary { parts.append(backupSummary) }
        return parts.joined(separator: " · ")
    }

    /// nil once the card is backed up, and while its backup state isn't known yet.
    private var backupSummary: String? {
        switch card.phase {
        case .needsBackup, .ready, .copying, .failed: break
        default: return nil
        }
        let notBackedUp = "\(card.missing.count) not backed up (\(Format.bytes(card.missingBytes)))"
        let backedUpCount = card.files.count - card.missing.count
        if backedUpCount > 0 && !card.missing.isEmpty {
            return "\(notBackedUp) · \(backedUpCount) already backed up"
        }
        if model.workingVolume != nil {
            return notBackedUp
        }
        return nil
    }

    // MARK: Cameras

    private var cameraList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(card.cameras) { camera in
                VStack(alignment: .leading, spacing: 3) {
                    Label(camera.label, systemImage: "video")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    dayChips(card.shootDays[camera.id] ?? [])
                }
            }
        }
    }

    @ViewBuilder private func dayChips(_ days: [ShootDay]) -> some View {
        if !days.isEmpty {
            let calendar = Calendar.current
            let hiddenDayCount = days.count - Self.maxDayChips
            HStack(spacing: 4) {
                ForEach(Array(days.prefix(Self.maxDayChips).enumerated()), id: \.offset) { _, day in
                    DayChip(day: day, calendar: calendar)
                }
                if hiddenDayCount > 0 {
                    Text("+\(hiddenDayCount)").font(.caption).foregroundStyle(.secondary)
                }
                if days.count > 1 {
                    Text("\(days.count) days").font(.caption).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    // MARK: Notes

    @ViewBuilder private var notes: some View {
        if let queueNote = card.queueNote {
            Label(queueNote, systemImage: "clock")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let mirrorNote = card.mirrorNote {
            Label(mirrorNote, systemImage: "externaldrive.badge.exclamationmark")
                .font(.callout).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Add to shoot

    /// True when the shoot's day is one of the days this card recorded on.
    private func matchesCard(_ item: ShootItem) -> Bool {
        card.shootDays.values.contains { days in
            days.contains { model.calendar.isDate($0.start, inSameDayAs: item.date) }
        }
    }

    private func showAddFootageSheet(for item: ShootItem) {
        model.shootSheet = .add(shootID: item.id, cardID: card.id)
    }

    /// A menu of online shoots (the ones matching the card's days first), plus a one-click button
    /// for the best match.
    @ViewBuilder private var addToShoot: some View {
        let online = model.shoots.filter { $0.isConfirmedOnline }
        let matching = online.filter(matchesCard)
        let others = online.filter { !matchesCard($0) }.prefix(Self.maxOtherShootsInMenu)
        Menu("Add to Shoot") {
            if online.isEmpty {
                Text("No shoots yet")
            } else {
                ForEach(matching) { item in
                    Button { showAddFootageSheet(for: item) } label: {
                        Label(item.menuLabel, systemImage: "calendar.badge.checkmark")
                    }
                }
                if !matching.isEmpty && !others.isEmpty { Divider() }
                ForEach(Array(others)) { item in
                    Button(item.menuLabel) { showAddFootageSheet(for: item) }
                }
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(online.isEmpty)
        if card.phase != .copying, let bestMatch = matching.first {
            Button("Add to \(bestMatch.record.name)") { showAddFootageSheet(for: bestMatch) }
                .foregroundStyle(Theme.accent)
        }
    }

    // MARK: Phase content

    @ViewBuilder private var phaseContent: some View {
        switch card.phase {
        case .scanning:
            ProgressView().controlSize(.small)
        case .verifying:
            verifyingContent
        case .needsBackup:
            needsBackupContent
        case .ready:
            if let plan = card.plan { readyContent(plan) }
        case .copying:
            copyingContent
        case .backed:
            backedContent
        case .empty:
            emptyContent
        case .unreadable(let message):
            unreadableContent(message)
        case .failed(let message):
            failedContent(message)
        }
    }

    private var showInFinderButton: some View {
        Button("Show in Finder") { model.openInFinder(card) }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func errorMessage(_ message: String) -> some View {
        ErrorLabel(message)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var verifyingContent: some View {
        let progress = card.verifyProgress
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.fraction)
            HStack {
                Text("Checking backup… \(progress.currentFileNumber)/\(progress.filesTotal)")
                    .monospacedDigit()
                Spacer()
                Text(progress.currentFile).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        caption("Comparing each file with the copy on \(model.workingDriveName). Don't format yet.")
        HStack { Spacer(); addToShoot }
    }

    @ViewBuilder private var needsBackupContent: some View {
        let workingDriveIsUnplugged = model.workRoot != nil && model.workingVolume == nil
        if workingDriveIsUnplugged {
            Text("\(model.workingDriveName) isn't plugged in, so this card can't be checked. Don't format.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Don't format this card yet.").font(.callout).foregroundStyle(.secondary)
        }
        HStack {
            showInFinderButton
            Spacer()
            Button("Choose folder…") { model.chooseFolder(for: card) }
            addToShoot
            Button("New Shoot…") { model.newShoot(card: card) }
                .buttonStyle(.borderedProminent)
                .disabled(model.workRoot == nil || model.workingVolume == nil)
        }
    }

    @ViewBuilder private func readyContent(_ plan: CopyPlan) -> some View {
        Text("Copy \(plan.jobs.count) files · \(Format.bytes(plan.bytes)) to \(plan.destinationLabel)")
            .font(.callout.weight(.medium))
        HStack {
            Button("Discard") { model.discardPlan(card) }
            showInFinderButton
            addToShoot
            Spacer()
            if isQueued {
                Button("Stop") { model.stop(card) }
            }
            Button(isQueued ? "Queued" : "Copy") { model.copy(card) }
                .buttonStyle(.borderedProminent)
                .disabled(isQueued)
        }
    }

    @ViewBuilder private var copyingContent: some View {
        let progress = card.progress
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.fraction)
            HStack {
                Text(progress.currentFile.isEmpty ? "Starting…" : progress.currentFile)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(progress.filesAndBytesText)
                    .monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            caption("Each file is checked against the card.")
            Spacer()
            Button("Stop") { model.stop(card) }
        }
    }

    @ViewBuilder private var backedContent: some View {
        HStack {
            if !card.files.isEmpty {
                Label("All on \(card.backedTo ?? model.workingDriveName) · Safe to format", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Spacer()
            addToShoot
            showInFinderButton
            Button(card.ejecting ? "Ejecting…" : "Eject") { model.eject(card) }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canEject(card))
        }
        if let ejectError = card.ejectError {
            Label(ejectError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var emptyContent: some View {
        Text("No media found on this card. Check it in Finder before you format it.")
            .font(.callout).foregroundStyle(.secondary)
        HStack {
            Spacer()
            showInFinderButton
        }
    }

    @ViewBuilder private func unreadableContent(_ message: String) -> some View {
        errorMessage(message)
        caption("Auto couldn't read everything on this card, so it can't tell if it's backed up. Don't format.")
        HStack {
            showInFinderButton
            Spacer()
            Button("Scan again") { model.rescan(card) }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private func failedContent(_ message: String) -> some View {
        let hasPlan = card.plan != nil
        errorMessage(message)
        caption(hasPlan
                ? "Nothing on the card was changed. Retry copies the files that didn't verify. Don't format."
                : "Nothing on the card was changed. Don't format until it's backed up.")
        HStack {
            if hasPlan { Button("Discard") { model.discardPlan(card) } }
            showInFinderButton
            addToShoot
            Spacer()
            Button("Choose folder…") { model.chooseFolder(for: card) }
            Button("Retry") { model.retry(card) }
                .buttonStyle(.borderedProminent)
                .disabled(isQueued)
        }
    }
}

/// Static status dot. Never animated.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }
}
