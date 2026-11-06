import Foundation

extension AppModel {
    /// Opens the Add Files sheet for a shoot, optionally pre-staged with dropped or chosen sources.
    func addFiles(to shootID: UUID, urls: [URL] = [], target: DropTarget = .sorted) {
        guard shoots.contains(where: { $0.id == shootID }) else { return }
        shootSheet = .addFiles(beginImport(shootID: shootID, urls: urls, target: target))
    }
}
