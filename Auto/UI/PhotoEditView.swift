import SwiftUI

/// Photo Edit tab: pick a shoot, cull its photos, undo the last cull. Progress for active culls is pinned at the bottom.
struct PhotoEditView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: UUID?

    private var ordered: [ShootItem] {
        let online = model.shoots.filter { Self.isOnline($0) }
        let rest = model.shoots.filter { !Self.isOnline($0) }
        return online + rest
    }

    private var activeIDs: [UUID] {
        ordered.map(\.id).filter {
            switch model.cullStates[$0] {
            case .waiting?, .running?: true
            default: false
            }
        }
    }

    static func isOnline(_ item: ShootItem) -> Bool {
        switch item.availability {
        case nil, .online?: true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.shoots.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 260)
                    ThemedDivider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if !activeIDs.isEmpty {
                ThemedDivider()
                VStack(spacing: 10) {
                    ForEach(activeIDs, id: \.self) { id in CullProgressRow(shootID: id) }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Theme.surface)
            }
        }
        .onAppear { if selectedID == nil { selectedID = ordered.first?.id } }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 72, height: 72)
                .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 18))
            Text("No shoots yet").font(.system(size: 17, weight: .semibold))
            Text("Create a shoot in Media, then cull its photos here.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(ordered) { item in
                    let online = Self.isOnline(item)
                    Button { selectedID = item.id } label: {
                        ShootCullRow(item: item, selected: selectedID == item.id)
                            .opacity(online ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder private var detail: some View {
        if let item = ordered.first(where: { $0.id == selectedID }) {
            CullDetail(item: item).id(item.id)
        } else {
            Text("Select a shoot").foregroundStyle(.secondary)
        }
    }
}

private func photosText(_ item: ShootItem) -> String? {
    guard let n = item.summary?.photoCount else { return nil }
    return "\(n) \(n == 1 ? "photo" : "photos")"
}

private struct ShootCullRow: View {
    @Environment(AppModel.self) private var model
    let item: ShootItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Theme.surfaceMuted
                .frame(width: 56, height: 36)
                .overlay {
                    if let image = item.thumbnail {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo").foregroundStyle(.quaternary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.record.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let t = photosText(item) { Text(t).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            badge
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(selected ? Theme.border : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var badge: some View {
        switch model.cullStates[item.id] {
        case .running?: pill("Culling", Theme.accent)
        case .waiting?: pill("Waiting", Theme.warning)
        case .finished(.completed)?: pill("Done", Theme.success)
        default: EmptyView()
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color == Theme.warning ? .primary : color)
    }
}

private struct CullDetail: View {
    @Environment(AppModel.self) private var model
    let item: ShootItem
    @State private var showSettings = false
    @State private var undoing = false

    private var state: CullState { model.cullStates[item.id] ?? .idle }
    private var isIdle: Bool {
        switch state {
        case .waiting, .running: false
        default: true
        }
    }

    var body: some View {
        let lastRun = model.lastCullRun(shootID: item.id)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.record.name).font(.system(size: 18, weight: .semibold))
                if let t = photosText(item) { Text(t).font(.callout).foregroundStyle(.secondary) }
            }
            if let run = lastRun {
                Text(Self.runLine(run)).font(.callout).foregroundStyle(.secondary)
                if let note = run.note {
                    Text(note).font(.caption).foregroundStyle(Theme.warning)
                }
            }
            HStack(spacing: 10) {
                Button("Start Cull…") { showSettings = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.cullBlockReason(shootID: item.id) != nil)
                Button("Undo Last Cull") {
                    undoing = true
                    Task { _ = await model.undoLastCull(shootID: item.id); undoing = false }
                }
                .disabled(lastRun == nil || lastRun?.undone == true || !isIdle || undoing)
            }
            if let reason = model.cullBlockReason(shootID: item.id) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            banner
            if let note = model.cullNotes[item.id] {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            rejectsSection
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) { await model.loadLastCullRun(shootID: item.id) }
        .sheet(isPresented: $showSettings) {
            CullSettingsSheet(shootID: item.id, onStart: {
                _ = model.startCull(shootID: item.id)
                showSettings = false
            }, onCancel: { showSettings = false })
        }
    }

    @ViewBuilder private var rejectsSection: some View {
        let rejects = model.cullLiveRejects[item.id] ?? []
        if !rejects.isEmpty {
            CullLiveRejectsGrid(rejects: rejects, running: !isIdle, applied: model.cullLiveRejectsApplied[item.id] ?? false)
        } else if !isIdle {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking at photos…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var banner: some View {
        if case .finished(let outcome) = state {
            switch outcome {
            case .completed(let s):
                bannerView("Moved \(s.rejected) rejects to _Rejects", "checkmark.circle.fill", Theme.success)
            case .stopped:
                bannerView("Stopped. Nothing was changed", "stop.circle.fill", .secondary)
            case .failed(let error, _):
                bannerView(error.errorDescription ?? "The cull failed", "exclamationmark.triangle.fill", .red)
            }
        }
    }

    private func bannerView(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
    }

    static func runLine(_ run: CullRunSummary) -> String {
        if run.undone { return "Last cull \(run.date.formatted(.dateTime.month(.abbreviated).day())) · Undone" }
        let cost = run.spentUSD.formatted(.currency(code: "USD"))
        return "Last cull \(run.date.formatted(.dateTime.month(.abbreviated).day())) · \(run.model.rawValue.capitalized) · \(run.rejected) of \(run.photos) moved to _Rejects · \(cost)"
    }
}

private struct CullProgressRow: View {
    @Environment(AppModel.self) private var model
    let shootID: UUID

    private var shootName: String {
        model.shoots.first { $0.id == shootID }?.record.name ?? "Shoot"
    }

    private var runningProgress: CullProgress? {
        if case .running(let progress)? = model.cullStates[shootID] { return progress }
        return nil
    }

    private var waitingReason: String? {
        if case .waiting(let reason)? = model.cullStates[shootID] { return reason }
        return nil
    }

    private func statusText(progress: CullProgress?, waiting: String?) -> String {
        if let waiting { return "Waiting: \(waiting)" }
        if let progress { return Self.text(progress.phase) }
        return ""
    }

    var body: some View {
        let progress = runningProgress
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(shootName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(statusText(progress: progress, waiting: waitingReason))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let progress { ProgressView(value: min(max(progress.fraction, 0), 1)) }
                else { ProgressView().progressViewStyle(.linear) }
            }
            Text((progress?.spentUSD ?? 0).formatted(.currency(code: "USD")) + " spent")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button("Stop") { model.stopCull(shootID: shootID) }.controlSize(.small)
        }
    }

    static func text(_ phase: CullPhase) -> String {
        switch phase {
        case .waiting(let r): "Waiting: \(r)"
        case .cataloging: "Reading photos"
        case .preparing(let d, let t): "Preparing previews \(d)/\(t)"
        case .analyzing(let d, let t): "Claude is reviewing group \(min(d + 1, max(t, 1))) of \(t)"
        case .finalRound(let d, let t): "Final round \(d)/\(t)"
        case .applying(let d, let t): "Moving rejects \(d)/\(t)"
        case .reverting: "Reverting…"
        case .undoing: "Undoing…"
        }
    }
}
