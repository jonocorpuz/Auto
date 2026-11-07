import Foundation

/// One thing the cull model may reject a photo for. The `id` is the stable
/// string stored in settings, prompts and journal entries.
nonisolated struct CullCriterion: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let definition: String

    static let exposure = CullCriterion(
        id: "exposure",
        title: "Exposure",
        definition: "Blown highlights or crushed shadows on the subject beyond recovery from RAW."
    )

    static let duplicates = CullCriterion(
        id: "duplicates",
        title: "Duplicates",
        definition: "Near-identical frames of the same pose; keep the best per the cull mode."
    )

    static let unusable = CullCriterion(
        id: "unusable",
        title: "Unusable",
        definition: "Motion blur or missed focus on the subject; accidental shots (ground, sky, lens cap, finger over lens)."
    )

    static let horizon = CullCriterion(
        id: "horizon",
        title: "Horizon",
        definition: "Crooked horizon that cannot be straightened without cropping the subject."
    )

    static let cropped = CullCriterion(
        id: "cropped",
        title: "Cropped subjects",
        definition: "Heads or limbs cut off at awkward joints by the frame edge."
    )

    static let eyes = CullCriterion(
        id: "eyes",
        title: "Eyes & expression",
        definition: "Closed eyes, mid-blink or clearly bad expressions on the main subjects."
    )

    static let all: [CullCriterion] = [exposure, duplicates, unusable, horizon, cropped, eyes]

    static func byID(_ id: String) -> CullCriterion? {
        all.first { $0.id == id }
    }
}
