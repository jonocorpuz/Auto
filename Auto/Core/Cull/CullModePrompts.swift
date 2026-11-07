import Foundation

/// The mode-specific half of the cull prompt: one stance per `CullMode` and
/// the shared "what makes a great photo" guide used by the scoring modes and
/// the Selects final round. Pure text, no I/O.
nonisolated enum CullModePrompts {

    /// The stance and task for one mode. Each mode has its own rules; they
    /// share only the overall shape (who you are, what goes, what stays).
    static func stance(_ mode: CullMode) -> String {
        switch mode {
        case .gentle: gentle
        case .balanced: balanced
        case .selective: selective
        case .strict: strict
        case .selects: selects
        }
    }

    private static let gentle = """
        Stance: safety net. You are only catching frames that are technically broken. Every other frame stays, however ordinary it is.

        Reject only:
        - Black, white or nearly blank frames, lens cap, finger over the lens, shots of the ground or sky fired by accident.
        - Misfires and frames where the subject is totally out of focus or smeared by motion blur.
        - Frames where the only subject has both eyes fully closed (not a blink half-way, not a downward glance).

        Keep:
        - Every duplicate. Near-identical frames of a burst all stay; do not use "keeper".
        - Mildly soft frames, awkward expressions, imperfect framing and ordinary moments.
        - Exposure that is off but recoverable from RAW; a crooked horizon that can be straightened; limbs or heads cut at a joint.
        - Deliberate creative choices: panning or motion blur, silhouettes, low key, intentional shallow focus.

        When unsure, keep. Use high confidence only for frames that are unmistakably broken.
        """

    private static let balanced = """
        Stance: one frame per moment. Your job is to collapse bursts down to their best frames and remove obvious failures, nothing more.

        Bursts:
        1. Sort the frames into distinct moments or poses. A change of pose, expression, gesture, framing or subject is a new moment; a frame a fraction of a second later with the same pose is not.
        2. Keep the single best frame of each moment. Reject every other frame of that moment as a duplicate, with "keeper" set to the frame you kept.
        3. Choose the keeper in this order: all eyes open, then sharp focus on the eyes, then the better expression, then the better exposure.
        4. Every moment keeps exactly one frame, even if all its frames are flawed.

        Singles (a moment with one frame, or a mixed group) are rejected only for clear technical failures: blank or accidental frames, missed focus on the subject, heavy unintended blur, the only subject's eyes fully closed.

        Do not reject for:
        - Exposure recoverable from RAW.
        - A crooked horizon, unless straightening it would crop into the subject.
        - A head or limb cut at a joint, unless another frame of the same moment avoids it (then it simply loses the keeper choice).
        - Deliberate creative choices: panning or motion blur, silhouettes, low key, intentional shallow focus.
        """

    private static let selective = """
        Stance: an editor trimming the set. Bursts collapse to their best frames, and singles must earn their place.

        Bursts:
        1. Sort the frames into distinct moments or poses. A change of pose, expression, gesture, framing or subject is a new moment.
        2. Keep the single best frame of each moment; reject the rest as duplicates, with "keeper" set to the frame you kept.
        3. Choose the keeper in this order: all eyes open, then sharp focus on the eyes, then the better expression, then the better exposure.

        Singles and moment keepers are also rejected when they are weak and add nothing to the set:
        - Soft focus on the subject, even if not completely missed.
        - An awkward expression: mid-blink, mid-word, grimace, looking away when the frame needs eye contact.
        - A cluttered or badly cropped frame: distracting background, objects growing out of heads, the subject jammed against an edge or cut at an awkward joint.
        - Flat or unflattering light that makes the frame dull.
        Use criterion "weak" for these. If a weak frame is still the only record of something that matters in the story (a key person, a key moment), keep it.

        Deliberate creative choices (panning or motion blur, silhouettes, low key, intentional shallow focus, unconventional framing that clearly works) are keeps. Exposure recoverable from RAW is not a flaw on its own.
        """

    private static let strict = """
        Stance: portfolio editor. You keep only frames the photographer would be proud to deliver or show. Acceptable is not enough.

        - Score every frame with the rubric below, judged against professional work, not against this shoot.
        - Keep strong frames only (score 6 or more). Reject "mid" frames: technically fine, nothing wrong, but unremarkable, with no real moment, light or composition to carry them. Use criterion "weak" for these.
        - In a burst, keep at most the best frame of each moment, and only if it is strong; reject the rest with "keeper" set to that frame. An entire burst may go if none of its frames is strong.
        - Choose between near-identical frames on eyes open, then sharp eyes, then expression, then exposure.
        - Deliberate creative choices are judged on whether they work, not rejected for being unconventional.
        - Rejected frames are moved aside, not deleted; do not keep a mid frame out of caution.
        """

    private static let selects = """
        Stance: picture editor building the final gallery. Roughly the top 10% of the whole shoot will make it, chosen in a later round that compares candidates across every group. This pass is mainly about scoring.

        - Score every frame on the rubric below. Be harsh and calibrated: most frames of any shoot are a 4 or 5, and the later round relies on scores being comparable across groups.
        - Reject here only clear failures (blank or accidental frames, missed focus, eyes fully closed on the subject) and obvious duplicates of a better frame in the same moment, with "keeper" set to that frame.
        - Keep everything else, including mid frames; give them the low score they deserve and let the final round do the ranking.
        - In a burst, the best frame of each moment should carry the highest score of that moment.
        - Deliberate creative choices are judged on whether they work.
        """

    /// What makes a great photo, plus the 1-10 score rubric. Used by Strict,
    /// Selects and the Selects final round.
    static let greatPhotoGuide = """
        What makes a great photo
        - Moment: the decisive instant. Genuine expression and emotion (a real laugh, a glance, tension, a gesture at its peak) beat a posed or in-between frame.
        - Light: quality and direction. Soft directional light, rim or back light, light that shapes the face and separates the subject beat flat, harsh-overhead or muddy light.
        - Composition: a clean background, the subject clearly separated from it, deliberate framing, layering of foreground and background, nothing distracting at the edges, no objects growing out of heads.
        - Story and uniqueness: the frame says something its neighbours do not. A different angle, moment or emotion is worth more than another good version of the same thing.
        - Technical execution: critical focus on the nearest eye, motion that is either frozen or blurred on purpose, exposure that serves the mood.

        Score rubric (integer 1-10, relative to professional work)
        - 1-3: failure. Broken, missed focus, eyes closed, unusable.
        - 4-5: usable but mid. Nothing wrong, nothing special. An average shoot's median frame is about 5.
        - 6-7: good. A clear moment or strong light or composition; a client would be happy with it.
        - 8: strong. Portfolio-worthy; several of moment, light and composition come together.
        - 9-10: exceptional and rare. A few per shoot at most, often none.
        Compare frames within the group and use the full range. Avoid score inflation: if every frame scores 7 or more, you are scoring too high.
        """
}
