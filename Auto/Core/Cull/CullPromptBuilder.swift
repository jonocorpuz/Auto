import Foundation

/// Builds every prompt the cull sends to Claude. Pure: no I/O, no SwiftUI.
///
/// Stable rules go in the workspace `CLAUDE.md` (`workspaceClaudeMD`). The
/// per-run criteria and strictness go in the appended run section. Each group
/// gets one user message listing its metrics and frame paths.
nonisolated enum CullPromptBuilder {

    /// Bump when any prompt text or the schema changes meaning.
    static let promptVersion = 1

    /// Written verbatim into `CullWorkspace/CLAUDE.md`.
    static let workspaceClaudeMD: String = #"""
        # Photo cull workspace

        You are a photo-culling assistant for a professional photographer. You see one group of frames at a time and decide keep or reject for every frame. Rejected frames are moved to a _Rejects folder, not deleted, but a wrong reject costs the photographer a picture: be conservative.

        ## How to work
        1. Read every image listed under FRAMES in a single turn (issue all Read calls together). A file ending in _faces.jpg is an enlarged strip of every detected face in that frame, numbered 0, 1, 2… left to right.
        2. Judge from the images. METRICS come from a local analyzer and are hints that can be wrong; the image is ground truth.
        3. Reply with JSON only, matching the schema, with exactly one entry per frame id. No prose.

        ## Hard rules
        - When uncertain, keep.
        - In a burst, first sort the frames into distinct poses or moments. Never reject every frame of a pose; keep at least one per pose.
        - To choose the keeper within a pose prefer, in order: all eyes open, then sharp focus on the subject's eyes, then better expression, then better exposure.
        - When you reject a frame because a similar frame is better, put that frame's id in "keeper".
        - A crooked horizon is a reject only if straightening it would crop into the subject.
        - Heads or limbs cut at an awkward joint (top of head through the eyes, wrist, elbow, knee, ankle) are a reject only when another frame of the same pose is better.
        - Exposure recoverable from RAW (mildly over or under) is not a reject.
        - Deliberate creative choices (panning motion blur, silhouettes, low key, intentional shallow focus) are keeps.
        - Judge only the criteria listed in the system prompt; ignore any other flaw.
        - reason: 12 words or fewer, concrete, e.g. "eyes closed; p02 sharper" or "lens cap, black frame".
        - criterion: the id of the criterion behind a reject. confidence: 0 to 1, how sure you are the verdict is right.
        """#

    /// One short paragraph for `--system-prompt`.
    static let roleSystemPrompt = "You cull photos for a professional photographer. Follow CLAUDE.md in this folder exactly. Output only JSON matching the schema."

    /// Strictness rule text per level, index 0 = level 1.
    private static let strictnessRules: [String] = [
        "Reject only obvious technical failures: black or white frames, lens cap, accidental shots, completely out of focus. Keep every duplicate.",
        "Reject clear technical failures and frames that are badly blurred or have the main subject's eyes fully closed. Keep duplicates unless they are virtually identical.",
        "Reject frames that clearly fail an enabled criterion. In bursts, reject near-identical frames that are clearly worse than the keeper of the same pose.",
        "Be selective. In bursts keep the best one or two frames per pose. Reject a frame with any enabled flaw when a better frame of the same moment exists.",
        "Keep only the single best frame per pose. Reject every other frame of a burst, and any single frame with a visible flaw on an enabled criterion.",
    ]

    /// The run section appended to the system prompt. A non-empty custom run
    /// prompt is returned verbatim; otherwise the criteria in use (in
    /// `CullCriterion.all` order) and the strictness rule are generated.
    static func runSection(settings: CullSettings) -> String {
        if let custom = settings.customRunPrompt, !custom.isEmpty {
            return custom
        }
        let level = min(max(settings.aggressiveness, 1), 5)
        let enabled = CullCriterion.all
            .filter { settings.criteria.contains($0.id) }
            .map { "- \($0.id): \($0.definition)" }
        let criteria = enabled.isEmpty ? "(none enabled)" : enabled.joined(separator: "\n")
        return """
        Criteria in use
        \(criteria)

        Strictness: level \(level) of 5
        \(strictnessRules[level - 1])
        """
    }

    /// Token per photo in group order: "p01", "p02"… Two digits minimum.
    static func tokens(for group: PhotoGroup) -> [String: String] {
        var out: [String: String] = [:]
        for (offset, photo) in group.photos.enumerated() {
            out[photo.id] = "p" + String(format: "%02d", offset + 1)
        }
        return out
    }

    /// The user message for one group. `frames` maps photo id to the preview
    /// path and optional face strip path, both relative to the run directory.
    /// Photos without a frames entry are left out of FRAMES.
    static func userMessage(
        group: PhotoGroup,
        index: Int,
        count: Int,
        tokens: [String: String],
        frames: [String: (preview: String, faces: String?)]
    ) -> String {
        let groupKind: String
        switch group.kind {
        case .burst:
            groupKind = "Burst: \(group.photos.count) frames of one scene within \(spanText(group))s. Compare them against each other."
        case .mixed:
            groupKind = "Mixed singles: \(group.photos.count) unrelated frames. Judge each on its own; do not use \"keeper\"."
        }

        let t0 = group.photos.first?.metrics?.captureTime
        let metricsLines = group.photos.compactMap { photo -> String? in
            guard let token = tokens[photo.id] else { return nil }
            return metricsLine(photo, token: token, t0: t0)
        }
        let frameLines = group.photos.compactMap { photo -> String? in
            guard let token = tokens[photo.id], let frame = frames[photo.id] else { return nil }
            let faces = frame.faces.map { " (faces: \($0))" } ?? ""
            return "\(token): \(frame.preview)\(faces)"
        }

        return """
        Group \(index) of \(count). \(groupKind)
        Camera: \(group.camera)

        METRICS (t = seconds after the first frame; sharp/fsharp = edge detail overall/on faces, higher is sharper, compare only within this group; clipHi/clipLo = % of pixels blown/crushed; tilt = horizon angle in degrees; eyesClosed and edgeCut list face numbers; faceQ = face quality 0-1)
        \(metricsLines.joined(separator: "\n"))

        FRAMES
        \(frameLines.joined(separator: "\n"))
        """
    }

    /// One metrics line, e.g.
    /// `p03 t+0.4s sharp=812 fsharp=430 mean=0.42 clipHi=0.2% clipLo=1.1% tilt=2.3 faces=6 eyesClosed=[2] edgeCut=[0] faceQ=0.71`.
    /// nil fields are omitted, face fields appear only with faces, and `t`
    /// needs both the frame's capture time and `t0`.
    static func metricsLine(_ p: PhotoRecord, token: String, t0: Date?) -> String {
        guard let m = p.metrics else { return "\(token) no metrics" }

        var parts = [token]
        if let captured = m.captureTime, let t0 {
            parts.append(String(format: "t%+.1fs", captured.timeIntervalSince(t0)))
        }
        parts.append(String(format: "sharp=%.0f", m.sharpness))
        if let faceSharpness = m.faceSharpness {
            parts.append(String(format: "fsharp=%.0f", faceSharpness))
        }
        parts.append(String(format: "mean=%.2f", m.meanLuma))
        parts.append(String(format: "clipHi=%.1f%%", m.clipHighPct))
        parts.append(String(format: "clipLo=%.1f%%", m.clipLowPct))
        if let tilt = m.horizonTiltDeg {
            parts.append(String(format: "tilt=%.1f", tilt))
        }
        if !m.faces.isEmpty {
            let closed = m.faces.enumerated().filter { $0.element.eyesClosed }.map { String($0.offset) }
            let cut = m.faces.enumerated().filter { $0.element.edgeCut }.map { String($0.offset) }
            parts.append("faces=\(m.faces.count)")
            parts.append("eyesClosed=[\(closed.joined(separator: ","))]")
            parts.append("edgeCut=[\(cut.joined(separator: ","))]")
            let qualities = m.faces.compactMap(\.quality)
            if !qualities.isEmpty {
                let mean = qualities.reduce(0, +) / Double(qualities.count)
                parts.append(String(format: "faceQ=%.2f", mean))
            }
        }
        return parts.joined(separator: " ")
    }

    /// JSON schema passed to `--json-schema`. One decision per frame id.
    static let jsonSchema: String = #"""
        {"type":"object","additionalProperties":false,"required":["decisions"],"properties":{"decisions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","verdict","reason","confidence"],"properties":{"id":{"type":"string","pattern":"^p[0-9]{2}$"},"verdict":{"enum":["keep","reject"]},"reason":{"type":"string","maxLength":90},"criterion":{"type":"string"},"keeper":{"type":"string","pattern":"^p[0-9]{2}$"},"confidence":{"type":"number","minimum":0,"maximum":1}}}}}}
        """#

    /// Seconds between the first and last frame, 1 dp. "?" unless both
    /// capture times are known.
    private static func spanText(_ group: PhotoGroup) -> String {
        guard
            let first = group.photos.first?.metrics?.captureTime,
            let last = group.photos.last?.metrics?.captureTime
        else { return "?" }
        return String(format: "%.1f", last.timeIntervalSince(first))
    }
}
