import Foundation

/// Builds every prompt the cull sends to Claude. Pure: no I/O, no SwiftUI.
///
/// Stable rules go in the workspace `CLAUDE.md` (`workspaceClaudeMD`). The
/// grading guide goes in the appended run section. Each group
/// gets one user message listing its metrics and frame paths.
nonisolated enum CullPromptBuilder {
    /// Bump when any prompt text or the schema changes meaning.
    static let promptVersion = 3

    // MARK: - First pass (one call per group)

    /// Written verbatim into `CullWorkspace/CLAUDE.md`. Mode-neutral: each
    /// cull's stance comes in the run section.
    static let workspaceClaudeMD: String = #"""
        # Photo cull workspace

        You grade photos for a professional event photographer. You see one group of frames at a time and describe every frame with a role, a moment label and four grades. The app decides what to keep from your grades.

        ## How to work
        1. Read every image listed under FRAMES in a single turn (issue all Read calls together). A file ending in _faces.jpg is an enlarged strip of every detected face in that frame, numbered 0, 1, 2… left to right.
        2. Judge from the images. METRICS come from a local analyzer and are hints that can be wrong; the image is ground truth.
        3. Reply with JSON only, matching the schema, with exactly one entry per frame id. No prose.

        ## Fields
        - role, moment, technical, composition, subject, story: as defined in the run section.
        - reason: 12 words or fewer, the most decisive thing about the frame, e.g. "trophy handover, winner beaming" or "eyes closed, soft focus".
        """#

    /// One short paragraph for `--system-prompt`.
    static let roleSystemPrompt = "You cull photos for a professional photographer. Follow CLAUDE.md in this folder exactly. Output only JSON matching the schema."

    /// The run section appended to the system prompt: a non-empty custom prompt for the
    /// current mode verbatim, otherwise the mode-neutral grading guide.
    static func runSection(settings: CullSettings) -> String {
        settings.customPrompt(for: settings.mode) ?? CullModePrompts.gradingGuide
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

        let firstCaptureTime = group.photos.first?.metrics?.captureTime
        let metricsLines = group.photos.compactMap { photo -> String? in
            guard let token = tokens[photo.id] else { return nil }
            return metricsLine(photo, token: token, t0: firstCaptureTime)
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

    /// JSON schema passed to `--json-schema`: one graded entry per frame id, every mode.
    static let jsonSchema: String = {
        let roles = FrameRole.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        func grade(_ min: Int) -> String { #"{"type":"integer","minimum":"# + "\(min)" + #","maximum":5}"# }
        return #"{"type":"object","additionalProperties":false,"required":["frames"],"properties":{"frames":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","role","moment","technical","composition","subject","story","reason"],"properties":{"id":{"type":"string","pattern":"^p[0-9]{2}$"},"role":{"enum":["#
            + roles
            + #"]},"moment":{"type":"string","pattern":"^m[0-9]{1,3}$"},"technical":"# + grade(1)
            + #","composition":"# + grade(1)
            + #","subject":"# + grade(0)
            + #","story":"# + grade(1)
            + #","reason":{"type":"string","maxLength":90}}}}}}"#
    }()

    // MARK: - Final round (Selects)

    /// `--system-prompt` for the Selects final round.
    static let finalRoundSystemPrompt = "You are the picture editor choosing the final gallery for a professional photographer. Read every candidate frame, compare them against each other, and output only JSON matching the schema."

    /// The run section for the final round. Never replaced by a custom prompt.
    static func finalRoundRunSection(settings: CullSettings) -> String {
        """
        Final round: choose the selects
        These candidate frames come from across the whole shoot. Each survived the first pass, which saw one group at a time, and carries its first-pass score (1-10) and role as hints. From these candidates pick exactly the number of frames the message asks for, best first.
        - Favour variety: do not pick near-duplicates of the same moment. When several candidates show one moment, pick only the strongest frame of it.
        - Prefer frames that add something different to the gallery: another moment, person, angle or emotion.
        - The image is ground truth; scores are hints.
        - reason: 10 words or fewer, concrete, e.g. "peak laugh, clean background".

        \(CullModePrompts.finalRoundGuide)
        """
    }

    /// The user message for one final-round batch. `frames` are the
    /// candidates in presentation order with their round-local tokens.
    static func finalRoundUserMessage(
        round: Int,
        batch: Int,
        batchCount: Int,
        pick: Int,
        frames: [(token: String, path: String, score: Int, role: String?)]
    ) -> String {
        let lines = frames.map { frame in
            let role = frame.role.map { ", \($0)" } ?? ""
            return "\(frame.token): \(frame.path) (score \(frame.score)\(role))"
        }
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

    // MARK: - Helpers

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
