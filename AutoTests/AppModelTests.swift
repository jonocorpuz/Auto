import Foundation
import Testing
@testable import Auto

struct AppModelTests {
    @Test func startsIdle() {
        #expect(AppModel().status == .idle)
    }

    @Test(arguments: AppModel.Status.allCases)
    func everyStatusHasLabelAndTint(_ status: AppModel.Status) {
        #expect(!status.label.isEmpty)
        _ = status.tint
    }
}
