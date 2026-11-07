import Foundation

/// Builds every prompt the cull sends to Claude. Pure: no I/O, no SwiftUI.
///
/// Stable rules go in the workspace `CLAUDE.md` (`workspaceClaudeMD`). The
/// per-run criteria and mode stance go in the appended run section. Each group
/// gets one user message listing its metrics and frame paths.
nonisolated enum CullPromptBuilder {

    /// Bump when any prompt text or the schema changes meaning.
    static let promptVersion = 2

    /// Written verbatim into `CullWorkspace/CLAUDE.md`. Mode-neutral: each
    /// cull's stance comes in the run section.
    static let workspaceClaudeMD: String = #"""
        # Photo cull workspace

        You are a photo-culling assistant for a professional photographer. You see one group of frames at a time and decide keep or reject for every frame. Rejected frames are moved to a _Rejects folder, not deleted.

        ## How to work
        1. Read every image listed under FRAMES in a single turn (issue all Read calls together). A file ending in _faces.jpg is an enlarged strip of every detected face in that frame, numbered 0, 1, 2… left to right.
        2. Judge from the images. METRICS come from a local analyzer and are hints that can be wrong; the image is ground truth.
        3. Reply with JSON only, matching the schema, with exactly one entry per frame id. No prose.

        ## This run
        Each run states the stance and task for this cull; follow it. The criteria it lists are the flaws that can justify a reject; the stance says how hard to apply them and whether quality alone may also justify one.

        ## Fields
        - reason: 12 words or fewer, concrete, e.g. "eyes closed; p02 sharper" or "lens cap, black frame".
        - criterion: the id of the criterion behind a reject, or "weak" when the frame goes on quality alone.
        - keeper: when you reject a frame because a similar frame is better, that frame's id.
        - confidence: 0 to 1, how sure you are the verdict is right.
        - score: only when the schema asks for it, an integer 1 to 10 for every frame, kept or rejected, using the rubric in the run section.
        """#

    /// One short paragraph for `--system-prompt`.
    static let roleSystemPrompt = "You cull photos for a professional photographer. Follow CLAUDE.md in this folder exactly. Output only JSON matching the schema."

    /// The run section appended to the system prompt. A non-empty custom
    /// prompt for the current mode is returned verbatim; otherwise the
    /// criteria in use (in `CullCriterion.all` order), the mode and its
    /// stance, plus the great-photo guide for scoring modes.
    static func runSection(settings: CullSettings) -> String {
        if let custom = settings.customPrompt(for: settings.mode) {
            return custom
        }
        let mode = settings.mode
        let enabled = CullCriterion.all
            .filter { settings.criteria.contains($0.id) }
            .map { "- \($0.id): \($0.definition)" }
        let criteria = enabled.isEmpty ? "(none enabled)" : enabled.joined(separator: "\n")
        var section = """
        Criteria in use
        \(criteria)

        Mode: \(mode.title)
        \(CullModePrompts.stance(mode))
        """
        if mode.scoresFrames {
            section += "\n\n" + CullModePrompts.greatPhotoGuide
        }
        return section
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

    /// JSON schema for non-scoring modes, kept for existing callers. Same as
    /// `jsonSchema(for: .balanced)`.
    static let jsonSchema: String = jsonSchema(for: .balanced)

    /// JSON schema passed to `--json-schema`. One decision per frame id;
    /// scoring modes add a required 1-10 `score`.
    static func jsonSchema(for mode: CullMode) -> String {
        let required = mode.scoresFrames
            ? #"["id","verdict","reason","confidence","score"]"#
            : #"["id","verdict","reason","confidence"]"#
        let score = mode.scoresFrames
            ? #","score":{"type":"integer","minimum":1,"maximum":10}"#
            : ""
        return #"{"type":"object","additionalProperties":false,"required":["decisions"],"properties":{"decisions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":"#
            + required
            + #","properties":{"id":{"type":"string","pattern":"^p[0-9]{2}$"},"verdict":{"enum":["keep","reject"]},"reason":{"type":"string","maxLength":90},"criterion":{"type":"string"},"keeper":{"type":"string","pattern":"^p[0-9]{2}$"},"confidence":{"type":"number","minimum":0,"maximum":1}"#
            + score
            + "}}}}}"
    }

    // MARK: Final round (Selects)

    /// `--system-prompt` for the Selects final round.
    static let finalRoundSystemPrompt = "You are the picture editor choosing the final gallery for a professional photographer. Read every candidate frame, compare them against each other, and output only JSON matching the schema."

    /// The run section for the final round. Never replaced by a custom prompt.
    static func finalRoundRunSection(settings: CullSettings) -> String {
        """
        Final round: choose the selects
        These candidate frames come from across the whole shoot. Each survived the first pass, which saw one group at a time, and carries its first-pass score as a hint. From these candidates pick exactly the number of frames the message asks for, best first.
        - Favour variety: do not pick near-duplicates of the same moment. When several candidates show one moment, pick only the strongest frame of it.
        - Prefer frames that add something different to the gallery: another moment, person, angle or emotion.
        - The image is ground truth; scores are hints.
        - reason: 10 words or fewer, concrete, e.g. "peak laugh, clean background".

        \(CullModePrompts.greatPhotoGuide)
        """
    }

    /// The user message for one final-round batch. `frames` are the
    /// candidates in presentation order with their round-local tokens.
    static func finalRoundUserMessage(
        round: Int,
        batch: Int,
        batchCount: Int,
        pick: Int,
        frames: [(token: String, path: String, score: Int)]
    ) -> String {
        let lines = frames.map { "\($0.token): \($0.path) (score \($0.score))" }
        return """
        Final round \(round), batch \(batch) of \(batchCount): \(frames.count) candidates. Pick exactly \(pick), best first.
        Read every image listed under FRAMES in a single turn (issue all Read calls together).

        FRAMES
        \(lines.joined(separator: "\n"))
        """
    }

    /// JSON schema for the final round: picks in order, best first.
    static let finalRoundSchema: String = #"""
        {"type":"object","additionalProperties":false,"required":["picks"],"properties":{"picks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","reason"],"properties":{"id":{"type":"string","pattern":"^p[0-9]{2}$"},"reason":{"type":"string","maxLength":60}}}}}}
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
