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

    private var item: ShootItem? { model.shoots.first { $0.id == shootID } }
    private var card: Card? { model.cards.first { $0.id == cardID } }
    private var key: CoverageKey? { cardID.map { CoverageKey(shootID: shootID, cardID: $0) } }
    private var state: CoverageState? { key.flatMap { model.coverage[$0] } }
    private var done: ShootCoverage? {
        if case .done(let c)? = state { return c }
        return nil
    }
    private var shootName: String { item?.record.name ?? "this shoot" }
    private var dateText: String { (item?.date ?? Date()).formatted(.dateTime.month(.abbreviated).day().year()) }

    private func mutate(_ change: (inout ShootSelection) -> Void) {
        guard var sel = selection else { return }
        change(&sel)
        selection = sel
    }

    /// Days per camera group, from what is not yet in the shoot once known, else from every card file.
    private var days: [String: [ShootDay]] {
        guard let card else { return [:] }
        let files = done?.notInShoot ?? card.files
        return ShootSelection.days(missing: files, cameras: cameras, calendar: model.calendar)
    }

    /// Selected files not yet in the shoot.
    private var selectedFiles: [MediaFile] {
        guard let done, let selection else { return [] }
        return selection.filter(done.notInShoot)
    }

    /// Duplicates among the current selection (provisional until coverage is done).
    private var duplicates: IngestDuplicates.Report {
        guard let cardID else { return IngestDuplicates.Report() }
        return model.duplicates(shootID: shootID, cardID: cardID, candidates: selectedFiles)
    }

    private var addCount: Int {
        let selected = selectedFiles.count
        return copyDuplicates ? selected : max(0, selected - duplicates.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Footage").font(.system(size: 20, weight: .semibold))
                Text("\(shootName) · \(dateText)").font(.callout).foregroundStyle(.secondary)
            }

            cardPicker

            if card != nil {
                shootNotices
                banner
                duplicatesBlock
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !cameras.isEmpty || !(days[ShootSelection.otherID] ?? []).isEmpty { camerasSection }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 360)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }

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
        .padding(24)
        .frame(width: 500)
        .background(Theme.panel)
        .onAppear {
            cardID = initialCardID ?? model.cards.first?.id
            load()
        }
        .onChange(of: cardID) { load() }
        .onChange(of: model.cards.map(\.id)) {
            if cardID == nil || card == nil { cardID = model.cards.first?.id }
        }
    }

    private func load() {
        error = nil
        copyDuplicates = false
        guard let card, let id = cardID else { cameras = []; selection = nil; return }
        cameras = card.cameras
        selection = model.shootSheetDefaults(shootID: shootID, cardID: id)
        model.checkCoverage(shootID: shootID, cardID: id)
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
        switch state {
        case .checking(let p)?:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking card against \(shootName)… \(p.filesDone)/\(p.filesTotal)")
                    .font(.callout).monospacedDigit()
                Spacer()
            }
        case .done(let c)?:
            VStack(alignment: .leading, spacing: 4) {
                if c.dayTotal == 0 {
                    Label("No files from \(dateText) on this card", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                } else if c.isComplete {
                    Label("Complete — all \(Format.count(c.dayTotal, "file", "files")) from \(dateText) are in this shoot",
                          systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("\(c.dayTotal - c.dayInShoot) of \(Format.count(c.dayTotal, "file", "files")) from \(dateText) are not in this shoot yet",
                          systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
                let other = otherDayCount(c)
                if other > 0 {
                    Text("+\(Format.count(other, "file", "files")) from other days on this card")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        case .failed(let reason)?:
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var shootNotices: some View {
        let busy = model.isCopyingInto(shootID: shootID).flatMap { $0.id == cardID ? nil : $0 }
        let copies = item?.copies ?? []
        let online = copies.filter { $0.availability == .online }
        let offline = copies.filter { $0.availability == .offline }
        if busy != nil || copies.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                if let busy {
                    Label("\(busy.name) is copying into this shoot. Files it brings will be skipped when this copy starts.",
                          systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                if copies.count > 1, !online.isEmpty {
                    Label("Copies to \(Self.list(online.map(\.volumeName)))", systemImage: "externaldrive")
                        .foregroundStyle(.secondary)
                }
                if !offline.isEmpty {
                    let names = Self.list(offline.map(\.volumeName))
                    Label("\(names) \(offline.count == 1 ? "isn't" : "aren't") connected; it'll be marked to sync.",
                          systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(Theme.warning)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func list(_ names: [String]) -> String {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        switch unique.count {
        case 0: return ""
        case 1: return unique[0]
        default: return unique.dropLast().joined(separator: ", ") + " and " + unique[unique.count - 1]
        }
    }

    @ViewBuilder private var duplicatesBlock: some View {
        let report = duplicates
        if done != nil, !report.isEmpty {
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

    private func otherDayCount(_ c: ShootCoverage) -> Int {
        c.notInShoot.filter { model.calendar.startOfDay(for: $0.date) != c.day }.count
    }

    // MARK: Cameras

    private var camerasSection: some View {
        let sel = selection ?? ShootSelection(missing: [], cameras: [], calendar: model.calendar)
        let allDays = days
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Cameras") {
                Text(Format.count(addCount, "file", "files") + " selected").font(.caption).foregroundStyle(.secondary)
            }
            SurfaceCard(padding: 12) {
                VStack(spacing: 0) {
                    ForEach(Array($cameras.enumerated()), id: \.element.id) { index, $cam in
                        if index > 0 { divider }
                        groupBlock(id: cam.id, sel: sel, days: allDays[cam.id] ?? []) {
                            Image(systemName: "video")
                        } title: {
                            Text(cam.label)
                        } trailing: {
                            TextField("Folder", text: $cam.folderName)
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .inputStyle(focused: false)
                                .frame(width: 160)
                                .disabled(!sel.isIncluded(camera: cam.id))
                        }
                    }
                    if let other = allDays[ShootSelection.otherID], !other.isEmpty {
                        if !cameras.isEmpty { divider }
                        groupBlock(id: ShootSelection.otherID, sel: sel, days: other) {
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

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 10)
    }

    private func groupBlock<Icon: View, Title: View, Trailing: View>(
        id: String, sel: ShootSelection, days groupDays: [ShootDay],
        @ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let on = sel.isIncluded(camera: id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { on },
                    set: { value in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            mutate { $0.setCamera(id, included: value, days: groupDays.map(\.start)) }
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                icon()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
                title().lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .opacity(on ? 1 : 0.5)

            if on {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groupDays, id: \.start) { day in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { sel.isIncluded(camera: id, day: day.start) },
                                set: { value in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        mutate { $0.set(camera: id, day: day.start, included: value) }
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
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

    // MARK: Add

    private func add() {
        guard let card, let selection, let cardID else { return }
        working = true
        error = nil
        let cams = cameras
        Task {
            do {
                try await model.addFootage(shootID: shootID, cardID: cardID, cameras: cams, selection: selection,
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
