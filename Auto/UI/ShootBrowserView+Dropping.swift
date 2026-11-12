import SwiftUI

/// Finder drops onto the shoot browser. Drops are copies only: nothing is moved or overwritten.
extension ShootBrowserView {
    /// How often a staged drop is checked while its files are scanned and compared with the shoot.
    private static let stagingPollInterval = Duration.milliseconds(100)

    // MARK: Handling a drop

    /// Top level, Video and Photo open the Add Files sheet pre-staged; any other folder is staged,
    /// then confirmed with a dialog before anything is copied.
    func handleDrop(_ urls: [URL], into target: URL?) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, let root, pendingDrop == nil else { return false }
        let destination = target ?? root

        switch ShootBrowser.dropTarget(for: destination, root: root) {
        case .sorted:
            model.addFiles(to: item.id, urls: files, target: .sorted)
        case .exact(let exactFolder):
            let staged = model.beginImport(shootID: item.id, urls: files, target: .exact(exactFolder))
            let folderLabel = dropLabel(for: exactFolder, root: root)
            Task { await confirmWhenStaged(staged, label: folderLabel) }
        }
        return true
    }

    /// The folder's path inside the shoot ("Video/B-roll"), or the shoot's name for its top level.
    private func dropLabel(for folder: URL, root: URL) -> String {
        let components = ShootPlanner.relativeComponents(folder, to: root) ?? []
        let path = components.joined(separator: "/")
        return path.isEmpty ? item.record.name : path
    }

    /// Waits for staging to finish, then asks the user to confirm the copy (or says why there is
    /// nothing to copy).
    private func confirmWhenStaged(_ staged: ImportStaging, label: String) async {
        while true {
            switch staged.phase {
            case .ready:
                askToConfirm(staged, label: label)
                return
            case .failed(let message):
                dropError = message
                return
            default:
                try? await Task.sleep(for: Self.stagingPollInterval)
                if Task.isCancelled {
                    staged.cancel()
                    return
                }
            }
        }
    }

    private func askToConfirm(_ staged: ImportStaging, label: String) {
        if staged.selected.isEmpty {
            dropError = staged.items.isEmpty
                ? "There was nothing to copy in what you dropped."
                : "Everything you dropped is already in this shoot."
            staged.cancel()
            return
        }
        pendingDrop = PendingDrop(staging: staged, label: label,
                                  count: staged.selected.count, skipped: staged.skippedDuplicateCount)
    }

    // MARK: Confirmation dialog

    var dropConfirmTitle: String {
        guard let drop = pendingDrop else { return "" }
        return "Copy \(Format.count(drop.count, "file", "files")) into \(drop.label)?"
    }

    /// Dismissing the dialog any other way cancels the staged drop.
    var isDropConfirmShown: Binding<Bool> {
        Binding(get: { pendingDrop != nil },
                set: { isShown in
                    if !isShown, let drop = pendingDrop {
                        drop.staging.cancel()
                        pendingDrop = nil
                    }
                })
    }

    var isDropErrorShown: Binding<Bool> {
        Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })
    }

    @ViewBuilder func dropConfirmButtons(_ drop: PendingDrop) -> some View {
        Button("Copy") {
            do {
                try model.commitImport(drop.staging)
            } catch {
                dropError = error.localizedDescription
            }
            pendingDrop = nil
        }
        Button("Cancel", role: .cancel) {
            drop.staging.cancel()
            pendingDrop = nil
        }
    }

    func dropConfirmMessage(_ drop: PendingDrop) -> String {
        if drop.skipped > 0 {
            return "\(Format.count(drop.skipped, "file", "files")) already in this shoot will be skipped."
        }
        return "Files are copied; the originals are not touched."
    }
}
