import Foundation
import Testing
@testable import Auto

struct CullEstimatorTests {

    @Test func costGrowsWithPhotoCount() {
        let settings = CullSettings()
        let counts = [1, 8, 9, 100, 1000]
        var previous: (low: Double, high: Double) = (0, 0)
        for count in counts {
            let estimate = CullEstimator.estimate(photoCount: count, model: .sonnet, settings: settings)
            #expect(estimate.low > previous.low)
            #expect(estimate.high > previous.high)
            previous = (estimate.low, estimate.high)
        }
    }

    @Test func modelsOrderByPrice() {
        let settings = CullSettings()
        let haiku = CullEstimator.estimate(photoCount: 200, model: .haiku, settings: settings)
        let sonnet = CullEstimator.estimate(photoCount: 200, model: .sonnet, settings: settings)
        let opus = CullEstimator.estimate(photoCount: 200, model: .opus, settings: settings)

        #expect(opus.low > sonnet.low)
        #expect(sonnet.low > haiku.low)
        #expect(opus.high > sonnet.high)
        #expect(sonnet.high > haiku.high)
    }

    @Test func callsAreCeilingOfPhotosOverEight() {
        let settings = CullSettings()
        for count in [1, 7, 8, 9, 16, 17, 100] {
            let expected = Int((Double(count) / 8).rounded(.up))
            let estimate = CullEstimator.estimate(photoCount: count, model: .sonnet, settings: settings)
            #expect(estimate.calls == expected)
        }
    }

    @Test func zeroPhotosCostNothing() {
        let estimate = CullEstimator.estimate(photoCount: 0, model: .opus, settings: CullSettings())
        #expect(estimate.low == 0)
        #expect(estimate.high == 0)
        #expect(estimate.calls == 0)
    }

    @Test func bandIsSevenTenthsToOneAndAHalfOfPoint() {
        let estimate = CullEstimator.estimate(photoCount: 50, model: .haiku, settings: CullSettings())
        let point = estimate.high / 1.5
        #expect(abs(estimate.low - 0.7 * point) < 1e-9)
        #expect(estimate.low < estimate.high)
    }

    @Test func sonnetHundredPhotosMatchesWrittenAssumptions() {
        // 100 photos x (1000 + 0.3 x 300) input, 13 calls x 380 effective system tokens,
        // 5000 output tokens. Point = 113940 x $3/M + 5000 x $15/M = $0.41682.
        let estimate = CullEstimator.estimate(photoCount: 100, model: .sonnet, settings: CullSettings())
        #expect(estimate.calls == 13)
        #expect(abs(estimate.high - 0.62523) < 0.001)
        #expect(abs(estimate.low - 0.29177) < 0.001)
    }

    @Test func disablingFaceStripCriteriaLowersCost() {
        var faceless = CullSettings()
        faceless.criteria = ["exposure", "duplicates", "unusable", "horizon"]
        let withStrips = CullEstimator.estimate(photoCount: 100, model: .sonnet, settings: CullSettings())
        let without = CullEstimator.estimate(photoCount: 100, model: .sonnet, settings: faceless)
        #expect(without.high < withStrips.high)
    }

    private func cost(_ mode: CullMode) -> (low: Double, high: Double, calls: Int) {
        var settings = CullSettings()
        settings.mode = mode
        return CullEstimator.estimate(photoCount: 400, model: .sonnet, settings: settings)
    }

    @Test func modesOrderByCost() {
        #expect(cost(.selects).high > cost(.strict).high)
        #expect(cost(.strict).high == cost(.balanced).high)
        #expect(cost(.gentle).high <= cost(.balanced).high)
        #expect(cost(.selects).calls > cost(.strict).calls)
        #expect(cost(.strict).calls == cost(.balanced).calls)
    }
}
