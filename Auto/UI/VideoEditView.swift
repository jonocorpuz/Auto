import SwiftUI

/// Video Edit tab: pick a shoot, check it's ready, set options for the sync + Resolve build.
struct VideoEditView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: UUID?

    private var ordered: [ShootItem] {
        let withVideo = model.shoots.filter { ($0.summary?.videoCount ?? 1) > 0 }
        let online = withVideo.filter { PhotoEditView.isOnline($0) }
        let rest = withVideo.filter { !PhotoEditView.isOnline($0) }
        return online + rest
    }

    var body: some View {
        Group {
            if ordered.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 260)
                    Divider().overlay(Theme.border)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if selectedID == nil { selectedID = ordered.first?.id } }
        .task {
            await model.refreshVideoEditEnvironment(checkMCP: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await model.refreshVideoEditEnvironment(checkMCP: false)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 72, height: 72)
                .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 18))
            Text("No video shoots yet").font(.system(size: 17, weight: .semibold))
            Text("Ingest a shoot with video in Media, then sync and build it in Resolve here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(ordered) { item in
                    Button { selectedID = item.id } label: {
                        VideoShootRow(item: item, selected: selectedID == item.id)
                            .opacity(PhotoEditView.isOnline(item) ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder private var detail: some View {
        if let item = ordered.first(where: { $0.id == selectedID }) {
            VideoEditDetail(item: item).id(item.id)
        } else {
            Text("Select a shoot").foregroundStyle(.secondary)
        }
    }
}

private func mediaText(_ item: ShootItem) -> String? {
    guard let s = item.summary else { return nil }
    var parts = ["\(s.videoCount) \(s.videoCount == 1 ? "clip" : "clips")"]
    if s.audioCount > 0 { parts.append("\(s.audioCount) audio \(s.audioCount == 1 ? "file" : "files")") }
    return parts.joined(separator: " · ")
}

private struct VideoShootRow: View {
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
                        Image(systemName: "film").foregroundStyle(.quaternary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.record.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let t = mediaText(item) { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(selected ? Theme.border : .clear))
        .contentShape(Rectangle())
    }
}

private struct VideoEditDetail: View {
    @Environment(AppModel.self) private var model
    let item: ShootItem

    var body: some View {
        @Bindable var model = model
        let readiness = model.videoEditReadiness(shootID: item.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.record.name).font(.system(size: 18, weight: .semibold))
                    if let t = mediaText(item) { Text(t).font(.callout).foregroundStyle(.secondary) }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Before you start")
                        ForEach(readiness.checks) { CheckRow(check: $0) }
                    }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader("What Auto will do")
                        OptionRow(title: "Sync speeches and ceremonies by audio",
                                  detail: "Cameras and recorders lined up by sound, no matching timecode needed. One timeline per event, cameras stacked on their own tracks. Claude works through the clips the audio can't settle.",
                                  isOn: $model.videoEditSettings.syncByAudio)
                        OptionRow(title: "Leave out accidental clips",
                                  detail: "Very short, black, or dark and silent recordings go in a Rejects bin, off the timelines. Files are never moved.",
                                  isOn: $model.videoEditSettings.leaveOutAccidental)
                        Label("Everything else goes on one timeline in recording order.", systemImage: "rectangle.stack")
                            .font(.callout).foregroundStyle(.secondary)
                        Label("Builds a new Resolve project named “\(item.record.name)”. Existing projects are never changed.",
                              systemImage: "lock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Claude")
                        HStack(spacing: 16) {
                            Picker("Model", selection: $model.videoEditSettings.model) {
                                ForEach(CullModel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 260)
                            HStack(spacing: 6) {
                                Text("Budget").foregroundStyle(.secondary)
                                TextField("Budget", value: $model.videoEditSettings.maxRunBudgetUSD,
                                          format: .currency(code: "USD"))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                    .labelsHidden()
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Button("Build in Resolve") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                    Text(readiness.blocker ?? "Coming soon: the sync engine is still being built.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CheckRow: View {
    let check: VideoEditReadiness.Check

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.callout)
                if check.state == .missing, let hint = check.hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch check.state {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .missing: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warning)
        case .checking: ProgressView().controlSize(.mini)
        }
    }
}

private struct OptionRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }
}
