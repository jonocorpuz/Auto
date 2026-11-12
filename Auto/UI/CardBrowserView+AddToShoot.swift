import SwiftUI

/// The card browser's file menu and its Add to Shoot flow, including the duplicate check.
extension CardBrowserView {
    /// How many "in <shoot>" places the duplicates dialog names before it says "and elsewhere".
    private static let maxPlacesNamed = 3

    // MARK: File menu

    @ViewBuilder func fileMenu(_ files: [MediaFile], groups: [CardBrowser.Group]) -> some View {
        Button("Quick Look") { quickLook(files) }
        Button("Show in Finder") { model.revealInFinder(files.map(\.url)) }
        let backupCopies = model.browserBackupCopies(files, in: location)
        if !backupCopies.isEmpty {
            let everyFileHasACopy = backupCopies.count == files.count
            Button(everyFileHasACopy ? "Show Backup in Finder" : "Show Backups in Finder (\(backupCopies.count))") {
                model.revealInFinder(backupCopies)
            }
        }
        Divider()
        addToShootItems(files, groups: groups)
    }

    // MARK: Add to Shoot menu

    func addToShootMenu(_ files: [MediaFile], groups: [CardBrowser.Group]) -> some View {
        Menu {
            addToShootItems(files, groups: groups)
        } label: {
            Label(adding ? "Adding…" : "Add to Shoot", systemImage: "plus.rectangle.on.folder")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(files.isEmpty || !canAdd || onlineShoots.isEmpty)
        .help(files.isEmpty ? "Select files to add them to a shoot" : "Copy the selected files into a shoot")
    }

    @ViewBuilder private func addToShootItems(_ files: [MediaFile], groups: [CardBrowser.Group]) -> some View {
        let shoots = onlineShoots
        if shoots.isEmpty {
            Text("No shoots online")
        } else {
            Section("Add \(Format.count(files.count, "file", "files")) to") {
                ForEach(shoots) { shoot in
                    // Files already verified inside this shoot are skipped; disable if that's all of them.
                    let alreadyInShoot = filesAlreadyIn(shoot.id, groups: groups)
                    let nothingToAdd = files.allSatisfy { alreadyInShoot.contains($0.id) }
                    Button(shoot.menuLabel) {
                        add(files, to: shoot.id)
                    }
                    .disabled(!canAdd || nothingToAdd)
                }
            }
        }
    }

    private var onlineShoots: [ShootItem] {
        model.shoots.filter { $0.isConfirmedOnline }
    }

    /// No adding while the card is still being read, is copying, or already has a copy planned.
    private var canAdd: Bool {
        guard !adding, card.plan == nil else { return false }
        switch card.phase {
        case .scanning, .copying, .empty, .unreadable: return false
        default: return card.engine == nil
        }
    }

    /// Prefer the shoot's verified membership; until it is known, use what the group shows.
    private func filesAlreadyIn(_ shootID: UUID, groups: [CardBrowser.Group]) -> Set<MediaFile.ID> {
        if case .done(let urls, _)? = model.browserMembership[shootID] {
            return Set(card.files.filter { urls.contains($0.url) }.map(\.id))
        }
        let shootGroup = groups.first { $0.kind == .shoot(shootID) }
        return Set(shootGroup?.files.map(\.id) ?? [])
    }

    // MARK: Adding

    /// Asks first when the selection holds files that already have a verified copy elsewhere.
    private func add(_ selected: [MediaFile], to shootID: UUID) {
        var files = selected
        if let remaining = filesKnownToBeOutsideShoot(selected, shootID: shootID) {
            if remaining.isEmpty {
                let shootName = model.shoots.first { $0.id == shootID }?.record.name ?? "this shoot"
                pendingAdd = PendingAdd(files: selected, shootID: shootID, duplicateCount: 0, places: "",
                                        inShootName: shootName)
                return
            }
            files = remaining
        }

        let duplicates = model.duplicates(shootID: shootID, cardID: card.id, candidates: files)
        if duplicates.isEmpty {
            start(files, to: shootID, includeDuplicates: false)
            return
        }

        let placeTitles = duplicates.byPlace.prefix(Self.maxPlacesNamed).map { "in \($0.place.title)" }
        let andElsewhere = duplicates.byPlace.count > Self.maxPlacesNamed ? ", and elsewhere" : ""
        pendingAdd = PendingAdd(files: files, shootID: shootID, duplicateCount: duplicates.count,
                                places: placeTitles.joined(separator: ", ") + andElsewhere)
    }

    /// The selected files that are not yet verified inside the shoot, so files already there are not
    /// part of the count. nil until the shoot's coverage of this card is known.
    private func filesKnownToBeOutsideShoot(_ selected: [MediaFile], shootID: UUID) -> [MediaFile]? {
        let coverageKey = CoverageKey(shootID: shootID, cardID: card.id)
        guard case .done(let coverage)? = model.coverage[coverageKey] else { return nil }
        let notInShoot = Set(coverage.notInShoot.map(\.url))
        return selected.filter { notInShoot.contains($0.url) }
    }

    private func start(_ files: [MediaFile], to shootID: UUID, includeDuplicates: Bool) {
        adding = true
        let urls = Set(files.map(\.url))
        Task {
            defer { adding = false }
            do {
                try await model.addFiles(urls, from: card.id, toShoot: shootID, includeDuplicates: includeDuplicates)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: Duplicates dialog

    func dialogTitle(_ pending: PendingAdd) -> String {
        if let shootName = pending.inShootName { return "All selected files are already in \(shootName)." }
        if pending.allDuplicates { return "All selected files are already backed up." }
        let places = pending.places.isEmpty ? "" : " (\(pending.places))"
        let notDuplicateCount = pending.files.count - pending.duplicateCount
        return "\(pending.duplicateCount) of \(pending.files.count) selected files are already backed up\(places). "
            + "Copy the other \(notDuplicateCount)?"
    }

    @ViewBuilder func pendingAddButtons(_ pending: PendingAdd) -> some View {
        if pending.inShootName != nil {
            Button("OK", role: .cancel) {}
        } else if pending.allDuplicates {
            Button("Copy Anyway") { start(pending.files, to: pending.shootID, includeDuplicates: true) }
        } else {
            let notDuplicateCount = pending.files.count - pending.duplicateCount
            Button("Copy \(Format.count(notDuplicateCount, "File", "Files"))") {
                start(pending.files, to: pending.shootID, includeDuplicates: false)
            }
            Button("Copy All \(pending.files.count)") {
                start(pending.files, to: pending.shootID, includeDuplicates: true)
            }
        }
        if pending.inShootName == nil { Button("Cancel", role: .cancel) {} }
    }
}
