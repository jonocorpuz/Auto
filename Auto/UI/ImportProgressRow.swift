import SwiftUI

/// One Add Files run: queued, copying, or how it ended. Sits beside the card rows.
struct ImportProgressRow: View {
    @Environment(AppModel.self) private var model
    let job: ImportJob

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
                    Text("Adding files to \(job.shootName)").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    trailing
                }
                content
            }
        }
        .task(id: isDone) {
            guard isDone else { return }
            let left = Self.minimumDuration - Date().timeIntervalSince(shownAt)
            if left > 0 { try? await Task.sleep(for: .seconds(left + 0.05)) }
            settled = true
        }
    }

    @ViewBuilder private var trailing: some View {
        if job.isActive {
            Button("Stop") { model.stopImport(job) }
        } else {
            Button("Dismiss") { model.dismissImport(job) }
        }
    }

    /// The bar never fills faster than this, so a quick import still reads as progress
    /// instead of flashing straight to "done". Longer imports follow the real copy progress.
    static let minimumDuration: TimeInterval = 1.5
    private var shownAt: Date { job.createdAt }
    @State private var settled = false

    /// Real progress: 0 while queued/preparing, the copy fraction while copying, 1 once it ended.
    private var realFraction: Double {
        switch job.phase {
        case .queued, .preparing: 0
        case .copying: job.progress.fraction
        case .done, .failed, .stopped: 1
        }
    }

    private func displayed(at now: Date) -> Double {
        let floor = min(1, now.timeIntervalSince(shownAt) / Self.minimumDuration)
        return min(realFraction, floor)
    }

    @ViewBuilder private var content: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
            let shown = displayed(at: context.date)
            if case .done = job.phase, shown >= 1 {
                outcome
            } else if case .failed = job.phase {
                outcome
            } else if case .stopped = job.phase {
                outcome
            } else if case .queued(let reason) = job.phase {
                Label(reason, systemImage: "clock").font(.callout).foregroundStyle(.secondary)
            } else {
                bar(shown)
            }
        }
    }

    /// Keep redrawing while the bar can still move; stop once the outcome is on screen.
    private var animating: Bool { job.isActive || (isDone && !settled) }

    private var isDone: Bool { if case .done = job.phase { true } else { false } }

    private func bar(_ fraction: Double) -> some View {
        let p = job.progress
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: fraction)
            HStack {
                Text(job.phase == .preparing ? "Checking files…" : (p.currentFile.isEmpty ? "Starting…" : p.currentFile))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if p.filesTotal > 0 {
                    Text("\(min(p.filesDone + 1, p.filesTotal)) of \(p.filesTotal) · \(Format.bytes(p.bytesDone)) of \(Format.bytes(p.bytesTotal))")
                        .monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var outcome: some View {
        switch job.phase {
        case .queued, .preparing, .copying:
            EmptyView()
        case .done(let summary):
            VStack(alignment: .leading, spacing: 4) {
                let text = "Added \(Format.count(summary.copied, "file", "files")) · \(Format.bytes(summary.bytes))"
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.callout)
                if summary.skippedDuplicates > 0 {
                    Text("\(summary.skippedDuplicates) already in the shoot, skipped").font(.caption).foregroundStyle(.secondary)
                }
                if let note = summary.note {
                    Label(note, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning)
                }
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        case .stopped:
            Label("Stopped. Files already copied are kept.", systemImage: "stop.circle").font(.callout).foregroundStyle(.secondary)
        }
    }
}
