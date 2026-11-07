import Foundation
import Testing
@testable import Auto

struct CullSettingsMigrationTests {
    private func decode(_ json: String) throws -> CullSettings {
        try JSONDecoder().decode(CullSettings.self, from: Data(json.utf8))
    }

    @Test(arguments: [(1, CullMode.gentle), (2, .gentle), (3, .balanced), (4, .balanced), (5, .balanced)])
    func legacyAggressivenessMaps(level: Int, mode: CullMode) throws {
        let s = try decode(#"{"aggressiveness":\#(level)}"#)
        #expect(s.mode == mode)
    }

    @Test func legacyCustomPromptFoldsIntoMigratedMode() throws {
        let s = try decode(#"{"aggressiveness":1,"customRunPrompt":"Mine"}"#)
        #expect(s.mode == .gentle)
        #expect(s.customPrompt(for: .gentle) == "Mine")
        #expect(s.customPrompt(for: .balanced) == nil)
    }

    @Test func legacyDefaultBudgetBecomesTen() throws {
        #expect(try decode(#"{"maxRunBudgetUSD":5.0}"#).maxRunBudgetUSD == 10)
        #expect(try decode(#"{"maxRunBudgetUSD":7.5}"#).maxRunBudgetUSD == 7.5)
    }

    @Test func emptyBlobDefaults() throws {
        let s = try decode("{}")
        #expect(s.mode == .balanced)
        #expect(s.maxRunBudgetUSD == 10)
    }

    @Test func newJSONRoundTripsAndDropsLegacyKeys() throws {
        var s = CullSettings(mode: .selects)
        s.setCustomPrompt("Top picks", for: .selects)
        let data = try JSONEncoder().encode(s)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("aggressiveness"))
        #expect(!text.contains("customRunPrompt"))
        #expect(try JSONDecoder().decode(CullSettings.self, from: data) == s)
    }

    @Test func customPromptsArePerModeAndResettable() {
        var s = CullSettings()
        s.setCustomPrompt("A", for: .gentle)
        s.setCustomPrompt("B", for: .strict)
        #expect(s.customPrompt(for: .gentle) == "A")
        #expect(s.customPrompt(for: .strict) == "B")
        s.setCustomPrompt(nil, for: .gentle)
        #expect(s.customPrompt(for: .gentle) == nil)
        #expect(s.customPrompt(for: .strict) == "B")
        s.setCustomPrompt("", for: .strict)
        #expect(s.customPrompts.isEmpty)
    }
}
