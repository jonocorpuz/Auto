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
    }

    @ViewBuilder private var trailing: some View {
        if job.isActive {
            Button("Stop") { model.stopImport(job) }
        } else {
            Button("Dismiss") { model.dismissImport(job) }
        }
    }

    @ViewBuilder private var content: some View {
        switch job.phase {
        case .queued(let reason):
            Label(reason, systemImage: "clock").font(.callout).foregroundStyle(.secondary)
        case .preparing:
            ProgressView().controlSize(.small)
        case .copying:
            let p = job.progress
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
