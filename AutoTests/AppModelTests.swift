import Foundation
import Testing
@testable import Auto

struct AppModelTests {
    @Test func startsIdle() {
        #expect(AppModel().status == .idle)
    }

    @Test(arguments: [AppModel.Status.idle, .working, .done, .error])
    func everyStatusHasSymbolAndLabel(_ status: AppModel.Status) {
        #expect(!status.symbol.isEmpty)
        #expect(!status.label.isEmpty)
    }
}
