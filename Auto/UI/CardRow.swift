import SwiftUI

/// One connected card: name, cameras, counts, state and the actions for its phase.
struct CardRow: View {
    @Environment(AppModel.self) private var model
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !card.cameras.isEmpty { cameraList }
            phaseContent
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(color: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name).font(.headline)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(phaseLabel).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        switch card.phase {
        case .scanning, .verifying, .empty: Color(nsColor: AppModel.Status.idle.tint)
        case .copying: Color(nsColor: AppModel.Status.copying.tint)
        case .backed: Color(nsColor: AppModel.Status.backed.tint)
        case .needsBackup, .ready: Color(nsColor: AppModel.Status.unbacked.tint)
        case .failed, .unreadable: Color(nsColor: AppModel.Status.error.tint)
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

    private var summary: String {
        guard !card.files.isEmpty else {
            return card.phase == .scanning ? "Counting files…" : "No photos or video on this card."
        }
        var parts: [String] = []
        if card.videoCount > 0 { parts.append("\(card.videoCount) video") }
        if card.photoCount > 0 { parts.append("\(card.photoCount) photo") }
        parts.append(Format.bytes(card.totalBytes))
        var text = parts.joined(separator: " · ")
        switch card.phase {
        case .needsBackup, .ready, .copying, .failed:
            if model.workingVolume != nil {
                text += " · \(card.missing.count) not on \(model.workingDriveName) yet (\(Format.bytes(card.missingBytes)))"
            }
        default: break
        }
        return text
    }

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
            HStack(spacing: 4) {
                ForEach(Array(days.prefix(4).enumerated()), id: \.offset) { _, day in
                    DayChip(day: day, calendar: calendar)
                }
                if days.count > 4 {
                    Text("+\(days.count - 4)").font(.caption).foregroundStyle(.secondary)
                }
                if days.count > 1 {
                    Text("\(days.count) days").font(.caption).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    // MARK: Add to shoot

    private var onlineShoots: [ShootItem] {
        model.shoots.filter { if case .online? = $0.availability { true } else { false } }
    }

    private func matchesCard(_ item: ShootItem) -> Bool {
        card.shootDays.values.contains { days in
            days.contains { model.calendar.isDate($0.start, inSameDayAs: item.date) }
        }
    }

    private func shootLabel(_ item: ShootItem) -> String {
        "\(item.record.name) — \(item.date.formatted(date: .abbreviated, time: .omitted))"
    }

    @ViewBuilder private var addToShoot: some View {
        let online = onlineShoots
        let matching = online.filter(matchesCard)
        let others = online.filter { !matchesCard($0) }.prefix(10)
        Menu("Add to Shoot") {
            if online.isEmpty {
                Text("No shoots yet")
            } else {
                ForEach(matching) { item in
                    Button { model.shootSheet = .add(shootID: item.id, cardID: card.id) } label: {
                        Label(shootLabel(item), systemImage: "calendar.badge.checkmark")
                    }
                }
                if !matching.isEmpty && !others.isEmpty { Divider() }
                ForEach(Array(others)) { item in
                    Button(shootLabel(item)) { model.shootSheet = .add(shootID: item.id, cardID: card.id) }
                }
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(online.isEmpty)
        if card.phase != .copying, let best = matching.first {
            Button("Add to \(best.record.name)") {
                model.shootSheet = .add(shootID: best.id, cardID: card.id)
            }
            .foregroundStyle(Theme.accent)
        }
    }

    // MARK: Phase content

    @ViewBuilder private var phaseContent: some View {
        switch card.phase {
        case .scanning:
            ProgressView().controlSize(.small)

        case .verifying:
            let p = card.verifyProgress
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p.fraction)
                HStack {
                    Text("Checking backup… \(min(p.filesDone + 1, p.filesTotal))/\(p.filesTotal)")
                        .monospacedDigit()
                    Spacer()
                    Text(p.currentFile).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Text("Comparing each file with the copy on \(model.workingDriveName). Don't format yet.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); addToShoot }

        case .needsBackup:
            if model.workRoot != nil && model.workingVolume == nil {
                Text("\(model.workingDriveName) isn't plugged in, so this card can't be checked. Don't format.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Don't format this card yet.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Show in Finder") { model.openInFinder(card) }
                Spacer()
                Button("Choose folder…") { model.chooseFolder(for: card) }
                addToShoot
                Button("New Shoot…") { model.newShoot(card: card) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.workRoot == nil || model.workingVolume == nil)
            }

        case .ready:
            if let plan = card.plan {
                Text("Copy \(plan.jobs.count) files · \(Format.bytes(plan.bytes)) to \(plan.destinationLabel)")
                    .font(.callout.weight(.medium))
                HStack {
                    Button("Discard") { model.discardPlan(card) }
                    Button("Show in Finder") { model.openInFinder(card) }
                    addToShoot
                    Spacer()
                    Button("Copy") { model.copy(card) }
                        .buttonStyle(.borderedProminent)
                }
            }

        case .copying:
            let p = card.progress
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p.fraction)
                HStack {
                    Text(p.currentFile.isEmpty ? "Starting…" : p.currentFile)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(min(p.filesDone + 1, p.filesTotal)) of \(p.filesTotal) · \(Format.bytes(p.bytesDone)) of \(Format.bytes(p.bytesTotal))")
                        .monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Each file is checked against the card.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { model.stop(card) }
            }

        case .backed:
            HStack {
                if !card.files.isEmpty {
                    Label("All on \(card.backedTo ?? model.workingDriveName) · Safe to format", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                Spacer()
                addToShoot
                Button("Show in Finder") { model.openInFinder(card) }
                Button(card.ejecting ? "Ejecting…" : "Eject") { model.eject(card) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canEject(card))
            }
            if let ejectError = card.ejectError {
                Label(ejectError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .empty:
            Text("No media found on this card. Check it in Finder before you format it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Show in Finder") { model.openInFinder(card) }
            }

        case .unreadable(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Auto couldn't read everything on this card, so it can't tell if it's backed up. Don't format.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Show in Finder") { model.openInFinder(card) }
                Spacer()
                Button("Scan again") { model.rescan(card) }
                    .buttonStyle(.borderedProminent)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if card.plan != nil { Button("Discard") { model.discardPlan(card) } }
                Button("Show in Finder") { model.openInFinder(card) }
                addToShoot
                Spacer()
                Button("Choose folder…") { model.chooseFolder(for: card) }
                Button("Retry") { model.retry(card) }
                    .buttonStyle(.borderedProminent)
            }
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
