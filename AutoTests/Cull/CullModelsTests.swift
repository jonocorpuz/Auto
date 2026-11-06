import Foundation
import Testing
@testable import Auto

struct CullModelsTests {

    @Test func settingsRoundTripThroughJSON() throws {
        var settings = CullSettings(
            criteria: ["exposure", "eyes"],
            aggressiveness: 4,
            model: .opus,
            customRunPrompt: "Keep everything sharp.",
            reviewBeforeApplying: true,
            maxConcurrentCalls: 3,
            maxRunBudgetUSD: 7.5
        )
        settings.customRunPrompt = "Keep everything sharp."

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CullSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func partialSettingsJSONDecodesAndClamps() throws {
        let json = Data(#"{"aggressiveness":9}"#.utf8)
        let settings = try JSONDecoder().decode(CullSettings.self, from: json)

        #expect(settings.aggressiveness == 5)
        #expect(settings.model == .sonnet)
        #expect(settings.maxConcurrentCalls == 2)
        #expect(settings.maxRunBudgetUSD == 5.0)
        #expect(settings.criteria == Set(CullCriterion.all.map(\.id)))
        #expect(settings.customRunPrompt == nil)
        #expect(settings.reviewBeforeApplying == false)
    }

    @Test func emptySettingsJSONDecodesToDefaults() throws {
        let settings = try JSONDecoder().decode(CullSettings.self, from: Data("{}".utf8))
        #expect(settings == CullSettings())
    }

    @Test func clampedPullsValuesIntoRange() {
        var low = CullSettings()
        low.aggressiveness = 0
        low.maxConcurrentCalls = 0
        low.maxRunBudgetUSD = 0.01
        let clampedLow = low.clamped()
        #expect(clampedLow.aggressiveness == 1)
        #expect(clampedLow.maxConcurrentCalls == 1)
        #expect(clampedLow.maxRunBudgetUSD == 0.1)

        var high = CullSettings()
        high.aggressiveness = 12
        high.maxConcurrentCalls = 9
        let clampedHigh = high.clamped()
        #expect(clampedHigh.aggressiveness == 5)
        #expect(clampedHigh.maxConcurrentCalls == 4)
        #expect(clampedHigh.maxRunBudgetUSD == 5.0)
    }

    @Test func criterionIDsAreUniqueAndComplete() {
        let ids = CullCriterion.all.map(\.id)
        #expect(CullCriterion.all.count == 6)
        #expect(Set(ids).count == ids.count)
        #expect(ids == ["exposure", "duplicates", "unusable", "horizon", "cropped", "eyes"])
        #expect(CullCriterion.byID("horizon")?.title == "Horizon")
        #expect(CullCriterion.byID("nope") == nil)
    }

    @Test func journalRunEventRoundTrips() throws {
        let runID = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CullJournalEvent.run(runID: runID, date: date, model: .haiku, settings: CullSettings())

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CullJournalEvent.self, from: data)

        guard case let .run(id, d, model, settings) = decoded else {
            Issue.record("Expected a run event")
            return
        }
        #expect(id == runID)
        #expect(d == date)
        #expect(model == .haiku)
        #expect(settings == CullSettings())
    }

    @Test func journalMovedEventRoundTrips() throws {
        let runID = UUID()
        let event = CullJournalEvent.moved(
            runID: runID,
            from: "Photo/A7/g01.jpg",
            to: "Photo/A7/_Rejects/g01.jpg",
            reason: "eyes closed; p02 sharper",
            criterion: "eyes",
            keeper: "p02",
            photoID: "Photo/A7/g01.jpg"
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CullJournalEvent.self, from: data)

        guard case let .moved(id, from, to, reason, criterion, keeper, photoID) = decoded else {
            Issue.record("Expected a moved event")
            return
        }
        #expect(id == runID)
        #expect(from == "Photo/A7/g01.jpg")
        #expect(to == "Photo/A7/_Rejects/g01.jpg")
        #expect(reason == "eyes closed; p02 sharper")
        #expect(criterion == "eyes")
        #expect(keeper == "p02")
        #expect(photoID == "Photo/A7/g01.jpg")
    }

    @Test func modelRawValuesAreCLIAliases() {
        #expect(CullModel.haiku.rawValue == "haiku")
        #expect(CullModel.sonnet.rawValue == "sonnet")
        #expect(CullModel.opus.rawValue == "opus")
        #expect(CullModel.allCases.count == 3)
    }

    @Test func errorDescriptionsMentionTheFix() {
        #expect(CullError.claudeNotInstalled.errorDescription?.contains("Claude Code CLI") == true)
        #expect(CullError.claudeNotLoggedIn.errorDescription?.contains("claude") == true)
        #expect(CullError.claudeNotLoggedIn.errorDescription?.contains("log in") == true)
    }
}
