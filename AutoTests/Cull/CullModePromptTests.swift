import Foundation
import Testing
@testable import Auto

struct CullModePromptTests {

    @Test func gradingGuideDefinesEveryRoleAndAxis() {
        let guide = CullModePrompts.gradingGuide
        for role in FrameRole.allCases {
            #expect(guide.contains("- \(role.rawValue):"), "guide missing role \(role)")
        }
        for axis in ["technical:", "composition:", "subject:", "story:", "Moments.", "Calibration:"] {
            #expect(guide.contains(axis), "guide missing \(axis)")
        }
    }

    @Test func gradingGuideCarriesTheTuningRules() {
        let guide = CullModePrompts.gradingGuide
        for term in ["Scale-aware", "Use 0 when no person matters", "cannot be recovered from RAW",
                     "someone pointing a camera at the lens", "A busy room is context",
                     "Feet or limbs cut off", "the app decides"] {
            #expect(guide.contains(term), "guide missing \(term)")
        }
    }

    @Test func finalRoundGuidePutsStoryFirst() {
        let guide = CullModePrompts.finalRoundGuide
        #expect(guide.contains("Story first"))
        #expect(guide.contains("milestones"))
        #expect(guide.contains("Variety"))
    }
}
