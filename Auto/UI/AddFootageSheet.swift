import SwiftUI

/// Add mode: pick a card, see how much of the shoot's day is already in the shoot, and copy the rest.
struct AddFootageSheet: View {
    @Environment(AppModel.self) private var model
    let shootID: UUID
    let initialCardID: Card.ID?

    @State private var cardID: Card.ID?
    @State private var cameras: [Camera] = []
    @State private var selection: ShootSelection?
    @State private var error: String?
    @State private var working = false
    @State private var copyDuplicates = false

    // MARK: Derived state

    private var item: ShootItem? { model.shoots.first { $0.id == shootID } }
    private var card: Card? { model.cards.first { $0.id == cardID } }
    private var shootName: String { item?.record.name ?? "this shoot" }
    private var dateText: String { (item?.date ?? Date()).formatted(.dateTime.month(.abbreviated).day().year()) }

    /// The check of the chosen card against the shoot; nil when no card is chosen or it hasn't started.
    private var coverageState: CoverageState? {
        guard let cardID else { return nil }
        return model.coverage[CoverageKey(shootID: shootID, cardID: cardID)]
    }

    /// The finished coverage check, once there is one.
    private var coverage: ShootCoverage? {
        if case .done(let coverage)? = coverageState { return coverage }
        return nil
    }

    /// Days per camera group, from what is not yet in the shoot once known, else from every card file.
    private var days: [String: [ShootDay]] {
        guard let card else { return [:] }
        let files = coverage?.notInShoot ?? card.files
        return ShootSelection.days(missing: files, cameras: cameras, calendar: model.calendar)
    }

    /// Selected files not yet in the shoot.
    private var selectedFiles: [MediaFile] {
        guard let coverage, let selection else { return [] }
        return selection.filter(coverage.notInShoot)
    }

    /// Duplicates among the current selection (provisional until coverage is done).
    private var duplicates: IngestDuplicates.Report {
        guard let cardID else { return IngestDuplicates.Report() }
        return model.duplicates(shootID: shootID, cardID: cardID, candidates: selectedFiles)
    }

    /// How many files the Add button will copy.
    private var addCount: Int {
        let selectedCount = selectedFiles.count
        if copyDuplicates { return selectedCount }
        return max(0, selectedCount - duplicates.count)
    }

    /// Files on the card that fit no camera.
    private var otherFilesDays: [ShootDay] {
        days[ShootSelection.otherID] ?? []
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "Add Footage", subtitle: "\(shootName) · \(dateText)")

            cardPicker

            if card != nil {
                shootNotices
                banner
                duplicatesBlock
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !cameras.isEmpty || !otherFilesDays.isEmpty { camerasSection }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 360)
            }

            if let error {
                ErrorLabel(error)
            }

            buttons
        }
        .padding(24)
        .frame(width: 500)
        .background(Theme.panel)
        .onAppear {
            cardID = initialCardID ?? model.cards.first?.id
            load()
        }
        .onChange(of: cardID) { load() }
        .onChange(of: model.cards.map(\.id)) {
            // The chosen card was unplugged (or none was chosen): fall back to the first one.
            if cardID == nil || card == nil { cardID = model.cards.first?.id }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { model.shootSheet = nil }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button(addCount == 0 ? "Add Files" : "Add \(Format.count(addCount, "file", "files"))") { add() }
                .buttonStyle(PrimaryPillButtonStyle())
                .frame(width: 160)
                .keyboardShortcut(.defaultAction)
                .disabled(addCount == 0 || working)
        }
    }

    /// Resets the sheet for the chosen card and starts checking it against the shoot.
    private func load() {
        error = nil
        copyDuplicates = false
        guard let card, let cardID else {
            cameras = []
            selection = nil
            return
        }
        cameras = card.cameras
        selection = model.shootSheetDefaults(shootID: shootID, cardID: cardID)
        model.checkCoverage(shootID: shootID, cardID: cardID)
    }

    // MARK: Card

    @ViewBuilder private var cardPicker: some View {
        if model.cards.isEmpty {
            SurfaceCard {
                HStack(spacing: 10) {
                    Image(systemName: "sdcard").foregroundStyle(.secondary)
                    Text("Connect a card to add footage.").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        } else {
            HStack {
                Text("Card").font(.system(size: 13, weight: .medium))
                Spacer()
                Picker("Card", selection: $cardID) {
                    ForEach(model.cards) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
        }
    }

    // MARK: Completeness

    @ViewBuilder private var banner: some View {
        switch coverageState {
        case .checking(let progress)?:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking card against \(shootName)… \(progress.filesDone)/\(progress.filesTotal)")
                    .font(.callout).monospacedDigit()
                Spacer()
            }
        case .done(let coverage)?:
            coverageSummary(coverage)
        case .failed(let reason)?:
            ErrorLabel(reason)
        case nil:
            EmptyView()
        }
    }

    private func coverageSummary(_ coverage: ShootCoverage) -> some View {
        let dayFiles = Format.count(coverage.dayTotal, "file", "files")
        let otherDayCount = otherDayCount(coverage)
        return VStack(alignment: .leading, spacing: 4) {
            if coverage.dayTotal == 0 {
                Label("No files from \(dateText) on this card", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else if coverage.isComplete {
                Label("Complete — all \(dayFiles) from \(dateText) are in this shoot",
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("\(coverage.dayTotal - coverage.dayInShoot) of \(dayFiles) from \(dateText) are not in this shoot yet",
                      systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            if otherDayCount > 0 {
                Text("+\(Format.count(otherDayCount, "file", "files")) from other days on this card")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    /// Files not in the shoot that were recorded on a different day than the shoot's.
    private func otherDayCount(_ coverage: ShootCoverage) -> Int {
        coverage.notInShoot.filter { model.calendar.startOfDay(for: $0.date) != coverage.day }.count
    }

    // MARK: Notices

    /// Another card that is copying into this shoot right now, if any.
    private var otherCardCopyingIntoShoot: Card? {
        guard let copyingCard = model.isCopyingInto(shootID: shootID) else { return nil }
        return copyingCard.id == cardID ? nil : copyingCard
    }

    @ViewBuilder private var shootNotices: some View {
        let busyCard = otherCardCopyingIntoShoot
        let copies = item?.copies ?? []
        let online = copies.filter { $0.availability == .online }
        let offline = copies.filter { $0.availability == .offline }
        if busyCard != nil || copies.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                if let busyCard {
                    Label("\(busyCard.name) is copying into this shoot. Files it brings will be skipped when this copy starts.",
                          systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                if copies.count > 1, !online.isEmpty {
                    Label("Copies to \(Self.sentenceList(online.map(\.volumeName)))", systemImage: "externaldrive")
                        .foregroundStyle(.secondary)
                }
                if !offline.isEmpty {
                    let names = Self.sentenceList(offline.map(\.volumeName))
                    Label("\(names) \(offline.count == 1 ? "isn't" : "aren't") connected; it'll be marked to sync.",
                          systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(Theme.warning)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "A", "A and B", "A, B and C", with repeated names dropped.
    private static func sentenceList(_ names: [String]) -> String {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        guard let last = unique.last else { return "" }
        if unique.count == 1 { return last }
        return unique.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: Duplicates

    @ViewBuilder private var duplicatesBlock: some View {
        let report = duplicates
        if coverage != nil, !report.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.byDrive, id: \.drive) { drive in
                    Label("\(Format.count(drive.count, "duplicate", "duplicates")) already on \(drive.drive) (\(Format.bytes(drive.bytes)))",
                          systemImage: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("Where") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(report.byPlace, id: \.place) { entry in
                            Text("\(entry.place.title) — \(Format.count(entry.count, "file", "files"))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
                Toggle("Copy duplicates anyway", isOn: $copyDuplicates)
            }
            .font(.callout)
        }
    }

    // MARK: Cameras

    private var camerasSection: some View {
        let shownSelection = selection ?? ShootSelection(missing: [], cameras: [], calendar: model.calendar)
        let daysByGroup = days
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Cameras") {
                Text(Format.count(addCount, "file", "files") + " selected").font(.caption).foregroundStyle(.secondary)
            }
            SurfaceCard(padding: 12) {
                VStack(spacing: 0) {
                    ForEach(Array($cameras.enumerated()), id: \.element.id) { index, $camera in
                        if index > 0 { rowDivider }
                        groupBlock(id: camera.id, selection: shownSelection, days: daysByGroup[camera.id] ?? []) {
                            Image(systemName: "video")
                        } title: {
                            Text(camera.label)
                        } trailing: {
                            TextField("Folder", text: $camera.folderName)
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .inputStyle(focused: false)
                                .frame(width: 160)
                                .disabled(!shownSelection.isIncluded(camera: camera.id))
                        }
                    }
                    if let otherDays = daysByGroup[ShootSelection.otherID], !otherDays.isEmpty {
                        if !cameras.isEmpty { rowDivider }
                        groupBlock(id: ShootSelection.otherID, selection: shownSelection, days: otherDays) {
                            Image(systemName: "doc")
                        } title: {
                            Text("Other files")
                        } trailing: {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 10)
    }

    /// One camera (or "Other files"): a checkbox row, then a checkbox per recording day while it is on.
    private func groupBlock<Icon: View, Title: View, Trailing: View>(
        id groupID: String, selection shownSelection: ShootSelection, days groupDays: [ShootDay],
        @ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let isIncluded = shownSelection.isIncluded(camera: groupID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                checkbox(isOn: isIncluded) { included in
                    updateSelection { $0.setCamera(groupID, included: included, days: groupDays.map(\.start)) }
                }
                icon()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
                title().lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .opacity(isIncluded ? 1 : 0.5)

            if isIncluded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groupDays, id: \.start) { day in
                        HStack(spacing: 8) {
                            checkbox(isOn: shownSelection.isIncluded(camera: groupID, day: day.start)) { included in
                                updateSelection { $0.set(camera: groupID, day: day.start, included: included) }
                            }
                            DayChip(day: day, calendar: model.calendar)
                            Spacer()
                        }
                    }
                }
                .padding(.leading, 40)
            }
        }
        .clipped()
    }

    /// An unlabelled checkbox whose change is animated, so day rows slide in and out.
    private func checkbox(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(
            get: { isOn },
            set: { included in
                withAnimation(.easeInOut(duration: 0.2)) {
                    onChange(included)
                }
            }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
    }

    private func updateSelection(_ change: (inout ShootSelection) -> Void) {
        guard var updated = selection else { return }
        change(&updated)
        selection = updated
    }

    // MARK: Add

    private func add() {
        guard let card, let selection, let cardID else { return }
        working = true
        error = nil
        let chosenCameras = cameras
        Task {
            do {
                try await model.addFootage(shootID: shootID, cardID: cardID, cameras: chosenCameras, selection: selection,
                                           includeDuplicates: copyDuplicates)
                model.copy(card)
                model.shootSheet = nil
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
