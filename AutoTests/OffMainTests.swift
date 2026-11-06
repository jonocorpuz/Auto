import Foundation
import Testing
@testable import Auto

/// Heavy walks must not run on the main actor even when awaited from it.
@MainActor struct OffMainTests {
    @Test func driveIndexAndCardScanRunOffTheMainThread() async throws {
        let card = try FixtureCard()
        defer { card.cleanup() }
        _ = await DriveIndex.build(card.root)
        _ = await CardScanner.scan(card.root, volumeName: "NO NAME")
        #expect(MainThreadProbe.shared.everRanOnMain("DriveIndex.build") == false)
        #expect(MainThreadProbe.shared.everRanOnMain("CardScanner.scan") == false)
    }
}
