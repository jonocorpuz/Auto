import Foundation
import Testing
@testable import Auto

struct CullModePromptTests {

    @Test func fiveDistinctStances() {
        let stances = CullMode.allCases.map(CullModePrompts.stance)
        #expect(Set(stances).count == CullMode.allCases.count)
        for stance in stances {
            #expect(!stance.isEmpty)
            #expect(stance.hasPrefix("Stance: "))
        }
    }

    @Test func eachStanceCarriesItsOwnRules() {
        let markers: [CullMode: [String]] = [
            .gentle: ["Every duplicate", "When unsure, keep", "lens cap"],
            .balanced: ["single best frame of each moment", "eyes open, then sharp focus on the eyes"],
            .selective: ["weak and add nothing", "badly cropped"],
            .strict: ["portfolio editor", "\"mid\" frames", "Score every frame", "entire burst may go"],
            .selects: ["picture editor", "top 10%", "Score every frame", "later round"],
        ]
        for (mode, terms) in markers {
            let stance = CullModePrompts.stance(mode)
            for term in terms {
                #expect(stance.contains(term), "\(mode) missing \(term)")
            }
        }
    }

    @Test func everyStanceKeepsDeliberateCreativeChoices() {
        for mode in CullMode.allCases {
            #expect(CullModePrompts.stance(mode).contains("Deliberate creative choices"))
        }
    }

    @Test func conservativeStancesCarryRecoveryCaveats() {
        for mode in [CullMode.gentle, .balanced] {
            let stance = CullModePrompts.stance(mode)
            #expect(stance.contains("RAW"))
            #expect(stance.contains("horizon"))
            #expect(stance.contains("joint"))
        }
    }

    @Test func greatPhotoGuideCoversTheBasicsAndRubric() {
        let guide = CullModePrompts.greatPhotoGuide
        for term in ["Moment", "Light", "Composition", "Story", "Technical execution",
                     "1-3", "4-5", "6-7", "8:", "9-10", "score inflation", "within the group"] {
            #expect(guide.contains(term), "guide missing \(term)")
        }
    }
}
