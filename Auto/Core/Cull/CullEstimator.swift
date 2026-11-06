import Foundation

/// Pre-run cost estimate for a cull. Pure.
///
/// Assumptions (all tunable here):
/// - Images: about 1000 input tokens per frame. That is a burst at the 1024px
///   preview. A mixed group at 768px is about 600. The estimator is not given
///   group kinds, so it uses the burst figure, which is the conservative one.
/// - Face strips: about 300 tokens each, assumed on 30% of photos. Only counted
///   while the `eyes` or `cropped` criterion is enabled, which is the same gate
///   the pipeline uses to write a strip.
/// - System prompt and workspace CLAUDE.md: about 1500 tokens per call. About
///   90% of it is a prompt-cache read billed at 0.1x. The other 10% is billed at
///   full price to cover cache misses.
/// - Output: about 40 tokens per photo.
/// - Calls: ceil(photos / 8), matching the grouper's singles batch.
/// - Prices in USD per million tokens (input / output): haiku 1 / 5,
///   sonnet 3 / 15, opus 5 / 25.
/// - low = 0.7 x point estimate, high = 1.5 x point estimate. The band is
///   deliberately wide because the grouping and the model's own output length
///   vary.
nonisolated enum CullEstimator {

    static let photosPerCall = 8
    static let imageTokensPerPhoto = 1000.0
    static let faceStripTokens = 300.0
    static let faceStripShare = 0.3
    static let systemTokensPerCall = 1500.0
    static let cachedShare = 0.9
    static let cacheReadMultiplier = 0.1
    static let outputTokensPerPhoto = 40.0
    static let lowFactor = 0.7
    static let highFactor = 1.5

    /// USD per million tokens (input, output).
    static func price(for model: CullModel) -> (input: Double, output: Double) {
        switch model {
        case .haiku: return (1, 5)
        case .sonnet: return (3, 15)
        case .opus: return (5, 25)
        }
    }

    static func estimate(
        photoCount: Int,
        model: CullModel,
        settings: CullSettings
    ) -> (low: Double, high: Double, calls: Int) {
        guard photoCount > 0 else { return (0, 0, 0) }

        let photos = Double(photoCount)
        let calls = (photoCount + photosPerCall - 1) / photosPerCall

        let stripShare = (settings.criteria.contains("eyes") || settings.criteria.contains("cropped"))
            ? faceStripShare
            : 0
        let photoInput = photos * (imageTokensPerPhoto + stripShare * faceStripTokens)
        let effectiveSystemTokens = systemTokensPerCall
            * (cachedShare * cacheReadMultiplier + (1 - cachedShare))
        let inputTokens = photoInput + Double(calls) * effectiveSystemTokens
        let outputTokens = photos * outputTokensPerPhoto

        let rate = price(for: model)
        let point = (inputTokens * rate.input + outputTokens * rate.output) / 1_000_000
        return (point * lowFactor, point * highFactor, calls)
    }
}
