import Foundation
import Testing
@testable import Auto

@MainActor
struct BrowsingExclusivityTests {
    private func makeModel() -> AppModel {
        let suite = "BrowsingExclusivityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let registry = FileManager.default.temporaryDirectory.appendingPathComponent("excl-\(UUID().uuidString).json")
        return AppModel(registryURL: registry, thumbnails: FakeThumbnailProvider(), defaults: defaults)
    }

    @Test func browsingAShootClosesTheCardBrowserAndViceVersa() {
        let model = makeModel()
        let card = Card(volume: FileManager.default.temporaryDirectory, name: "C", identity: "c-\(UUID().uuidString)")
        model._testInsert(card: card)
        model.browsingCardID = card.id
        model.browsingShootID = UUID()
        #expect(model.browsingCardID == nil)
        #expect(model.browsingShootID != nil)

        model.browsingCardID = card.id
        #expect(model.browsingShootID == nil)
        #expect(model.browsingCardID == card.id)
    }

    @Test func leavingTheMediaTabClosesTheShootBrowser() {
        let model = makeModel()
        model.browsingShootID = UUID()
        model.selectedTab = .videoEdit
        #expect(model.browsingShootID == nil)
    }
}
