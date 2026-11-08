import Foundation
import CoreGraphics
import Testing
@testable import Auto

struct CullPromptBuilderTests {

    private static let base = Date(timeIntervalSince1970: 1_000)

    private static func metrics(
        captureOffset: Double? = nil,
        sharpness: Double = 812.3,
        faceSharpness: Double? = nil,
        tilt: Double? = nil,
        faces: [FaceInfo] = []
    ) -> PhotoMetrics {
        PhotoMetrics(
            captureTime: captureOffset.map { base.addingTimeInterval($0) },
            meanLuma: 0.42,
            lumaStdDev: 0.2,
            clipHighPct: 0.2,
            clipLowPct: 1.1,
            sharpness: sharpness,
            faceSharpness: faceSharpness,
            dHash: 0,
            horizonTiltDeg: tilt,
            faces: faces
        )
    }

    private static func record(_ name: String, metrics: PhotoMetrics? = nil) -> PhotoRecord {
        PhotoRecord(
            id: name,
            camera: "A",
            members: [name],
            representative: name,
            stamps: [:],
            metrics: metrics
        )
    }

    private static func group(kind: GroupKind, _ photos: [PhotoRecord]) -> PhotoGroup {
        PhotoGroup(id: 7, kind: kind, camera: "A", photos: photos)
    }

    /// Three photos, captures at 0, 0.5 and 1.7 seconds.
    private static func burstGroup() -> PhotoGroup {
        group(kind: .burst, [
            record("a.jpg", metrics: metrics(captureOffset: 0)),
            record("b.jpg", metrics: metrics(captureOffset: 0.5)),
            record("c.jpg", metrics: metrics(captureOffset: 1.7)),
        ])
    }

    private static func framesFor(_ group: PhotoGroup) -> [String: (preview: String, faces: String?)] {
        var out: [String: (preview: String, faces: String?)] = [:]
        for photo in group.photos {
            out[photo.id] = (preview: "g07_\(photo.id)", faces: nil)
        }
        return out
    }

    // MARK: Criteria and strictness

    @Test func everyModeGetsTheSameGradingGuide() {
        for mode in CullMode.allCases {
            var settings = CullSettings()
            settings.mode = mode
            #expect(CullPromptBuilder.runSection(settings: settings) == CullModePrompts.gradingGuide)
        }
    }

    @Test func customRunPromptIsReturnedVerbatim() {
        var settings = CullSettings()
        let custom = "Keep only sharp frames.\n  Be strict about \"eyes\"."
        settings.setCustomPrompt(custom, for: settings.mode)
        #expect(CullPromptBuilder.runSection(settings: settings) == custom)
    }

    @Test func customPromptAppliesOnlyToItsMode() {
        for owner in CullMode.allCases {
            var settings = CullSettings()
            let custom = "Custom for \(owner.rawValue)."
            settings.setCustomPrompt(custom, for: owner)
            for mode in CullMode.allCases {
                settings.mode = mode
                let section = CullPromptBuilder.runSection(settings: settings)
                if mode == owner {
                    #expect(section == custom)
                } else {
                    #expect(!section.contains(custom))
                    #expect(section == CullModePrompts.gradingGuide)
                }
            }
        }
    }

    @Test func emptyCustomRunPromptFallsBackToGenerated() {
        var settings = CullSettings()
        settings.customPrompts[settings.mode.rawValue] = ""
        #expect(CullPromptBuilder.runSection(settings: settings) == CullModePrompts.gradingGuide)
    }

    @Test func noPlaceholdersInAnyOutput() {
        var settings = CullSettings()
        for mode in CullMode.allCases {
            settings.mode = mode
            #expect(!CullPromptBuilder.runSection(settings: settings).contains("{{"))
        }
        let group = Self.burstGroup()
        let message = CullPromptBuilder.userMessage(
            group: group, index: 1, count: 1,
            tokens: CullPromptBuilder.tokens(for: group),
            frames: Self.framesFor(group)
        )
        #expect(!message.contains("{{"))
        #expect(!CullPromptBuilder.workspaceClaudeMD.contains("{{"))
        #expect(!CullPromptBuilder.roleSystemPrompt.contains("{{"))
        #expect(!CullPromptBuilder.jsonSchema.contains("{{"))
        #expect(!CullPromptBuilder.metricsLine(Self.record("x.jpg", metrics: Self.metrics()), token: "p01", t0: nil).contains("{{"))
    }

    // MARK: Static text

    @Test func workspaceRulesAreTheVerbatimText() {
        let md = CullPromptBuilder.workspaceClaudeMD
        #expect(md.hasPrefix("# Photo cull workspace\n"))
        #expect(md.contains("## How to work\n1. Read every image listed under FRAMES"))
        #expect(md.contains("_faces.jpg"))
        #expect(md.contains("the image is ground truth"))
        #expect(md.contains("The app decides what to keep from your grades."))
        #expect(md.contains("- reason: 12 words or fewer"))
    }

    @Test func workspaceIsModeNeutral() {
        let md = CullPromptBuilder.workspaceClaudeMD
        #expect(!md.contains("conservative"))
        #expect(!md.contains("When uncertain"))
        #expect(!md.contains("Hard rules"))
        #expect(!md.contains("keep at least one per pose"))
    }

    @Test func roleSystemPromptIsVerbatim() {
        #expect(CullPromptBuilder.roleSystemPrompt == "You cull photos for a professional photographer. Follow CLAUDE.md in this folder exactly. Output only JSON matching the schema.")
    }

    @Test func promptVersionIsTwo() {
        #expect(CullPromptBuilder.promptVersion == 3)
    }

    private static func frameItem(_ schema: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
        let root = try #require(object)
        let properties = try #require(root["properties"] as? [String: Any])
        let frames = try #require(properties["frames"] as? [String: Any])
        return try #require(frames["items"] as? [String: Any])
    }

    @Test func gradingSchemaRequiresRoleMomentAndFourGrades() throws {
        let item = try Self.frameItem(CullPromptBuilder.jsonSchema)
        let props = try #require(item["properties"] as? [String: Any])
        let required = try #require(item["required"] as? [String])
        #expect(Set(required) == ["id", "role", "moment", "technical", "composition", "subject", "story", "reason"])
        let role = try #require(props["role"] as? [String: Any])
        #expect(role["enum"] as? [String] == FrameRole.allCases.map(\.rawValue))
        for (axis, low) in [("technical", 1), ("composition", 1), ("subject", 0), ("story", 1)] {
            let g = try #require(props[axis] as? [String: Any])
            #expect(g["minimum"] as? Int == low && g["maximum"] as? Int == 5, "\(axis)")
        }
        #expect(props["verdict"] == nil && props["confidence"] == nil)
    }

    @Test func finalRoundSchemaParses() throws {
        let object = try JSONSerialization.jsonObject(with: Data(CullPromptBuilder.finalRoundSchema.utf8)) as? [String: Any]
        let root = try #require(object)
        #expect(root["required"] as? [String] == ["picks"])
        let properties = try #require(root["properties"] as? [String: Any])
        let picks = try #require(properties["picks"] as? [String: Any])
        let item = try #require(picks["items"] as? [String: Any])
        let itemProps = try #require(item["properties"] as? [String: Any])
        let id = try #require(itemProps["id"] as? [String: Any])
        let reason = try #require(itemProps["reason"] as? [String: Any])
        #expect(id["pattern"] as? String == "^p[0-9]{2}$")
        #expect(reason["maxLength"] as? Int == 60)
    }

    @Test func finalRoundMessageListsPickCountAndEveryToken() {
        let frames: [(token: String, path: String, score: Int, role: String?)] = [
            ("p01", "final/p01.jpg", 8, "milestone"), ("p02", "final/p02.jpg", 6, nil), ("p03", "final/p03.jpg", 7, "group"),
        ]
        let message = CullPromptBuilder.finalRoundUserMessage(round: 1, batch: 2, batchCount: 3, pick: 2, frames: frames)
        #expect(message.contains("Pick exactly 2"))
        #expect(message.contains("batch 2 of 3"))
        for f in frames {
            #expect(message.contains("\(f.token): \(f.path) (score \(f.score)" + (f.role.map { ", \($0)" } ?? "") + ")"))
        }
    }

    @Test func finalRoundRunSectionIgnoresCustomPrompts() {
        var settings = CullSettings()
        settings.mode = .selects
        settings.setCustomPrompt("custom selects", for: .selects)
        let section = CullPromptBuilder.finalRoundRunSection(settings: settings)
        #expect(!section.contains("custom selects"))
        #expect(section.contains(CullModePrompts.finalRoundGuide))
        #expect(section.contains("near-duplicates"))
        #expect(section.contains("best first"))
        #expect(!CullPromptBuilder.finalRoundSystemPrompt.isEmpty)
    }

    @Test func jsonSchemaParses() throws {
        let data = Data(CullPromptBuilder.jsonSchema.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try #require(object)
        #expect(root["type"] as? String == "object")
        #expect(root["required"] as? [String] == ["frames"])
    }

    @Test func tokensAreZeroPaddedInGroupOrder() {
        let photos = (1...12).map { Self.record("img\($0).jpg") }
        let tokens = CullPromptBuilder.tokens(for: Self.group(kind: .mixed, photos))

        #expect(tokens.count == 12)
        #expect(tokens["img1.jpg"] == "p01")
        #expect(tokens["img9.jpg"] == "p09")
        #expect(tokens["img12.jpg"] == "p12")
        #expect(Set(tokens.values) == Set((1...12).map { String(format: "p%02d", $0) }))
    }

    // MARK: Metrics line

    @Test func fullMetricsLineIsExact() {
        let faces = (0..<6).map { index in
            FaceInfo(
                box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                eyesClosed: index == 2,
                edgeCut: index == 0,
                quality: 0.71
            )
        }
        let photo = Self.record("p.jpg", metrics: Self.metrics(
            captureOffset: 0.4,
            sharpness: 812.3,
            faceSharpness: 430.2,
            tilt: 2.3,
            faces: faces
        ))
        let line = CullPromptBuilder.metricsLine(photo, token: "p03", t0: Self.base)

        #expect(line == "p03 t+0.4s sharp=812 fsharp=430 mean=0.42 clipHi=0.2% clipLo=1.1% tilt=2.3 faces=6 eyesClosed=[2] edgeCut=[0] faceQ=0.71")
    }

    @Test func sparseMetricsLineOmitsNilFields() {
        let photo = Self.record("s.jpg", metrics: Self.metrics(sharpness: 12))
        let line = CullPromptBuilder.metricsLine(photo, token: "p07", t0: Self.base)

        #expect(line == "p07 sharp=12 mean=0.42 clipHi=0.2% clipLo=1.1%")
    }

    @Test func timeOmittedWhenCaptureOrOriginUnknown() {
        let timed = Self.record("t.jpg", metrics: Self.metrics(captureOffset: 2))
        #expect(!CullPromptBuilder.metricsLine(timed, token: "p01", t0: nil).contains(" t+"))

        let untimed = Self.record("u.jpg", metrics: Self.metrics())
        #expect(!CullPromptBuilder.metricsLine(untimed, token: "p01", t0: Self.base).contains(" t+"))
    }

    @Test func faceFieldsOnlyWhenFacesPresent() {
        let photo = Self.record("f.jpg", metrics: Self.metrics(faces: []))
        let line = CullPromptBuilder.metricsLine(photo, token: "p01", t0: nil)
        #expect(!line.contains("faces="))
        #expect(!line.contains("eyesClosed="))
        #expect(!line.contains("faceQ="))
    }

    // MARK: User message

    @Test func burstUserMessageHasSpanAndFrames() {
        let group = Self.burstGroup()
        let message = CullPromptBuilder.userMessage(
            group: group, index: 2, count: 5,
            tokens: CullPromptBuilder.tokens(for: group),
            frames: Self.framesFor(group)
        )

        #expect(message.hasPrefix("Group 2 of 5. Burst: 3 frames of one scene within 1.7s. Compare them against each other."))
        #expect(message.contains("Camera: A\n"))
        #expect(message.contains("p01: g07_a.jpg\n"))
        #expect(message.contains("p03: g07_c.jpg"))
        #expect(message.contains("FRAMES\n"))
    }

    @Test func burstSpanIsQuestionMarkWhenUnknown() {
        let group = Self.group(kind: .burst, [
            Self.record("a.jpg", metrics: Self.metrics(captureOffset: 0)),
            Self.record("b.jpg", metrics: Self.metrics()),
        ])
        let message = CullPromptBuilder.userMessage(
            group: group, index: 1, count: 1,
            tokens: CullPromptBuilder.tokens(for: group),
            frames: Self.framesFor(group)
        )
        #expect(message.contains("within ?s."))
    }

    @Test func mixedUserMessageUsesMixedText() {
        let group = Self.group(kind: .mixed, [
            Self.record("a.jpg", metrics: Self.metrics(captureOffset: 0)),
            Self.record("b.jpg", metrics: Self.metrics(captureOffset: 90)),
        ])
        let message = CullPromptBuilder.userMessage(
            group: group, index: 1, count: 1,
            tokens: CullPromptBuilder.tokens(for: group),
            frames: Self.framesFor(group)
        )
        #expect(message.hasPrefix("Group 1 of 1. Mixed singles: 2 unrelated frames. Judge each on its own; do not use \"keeper\"."))
        #expect(!message.contains("Burst:"))
    }

    @Test func facesPathAppearsOnFrameLine() {
        let group = Self.burstGroup()
        var frames = Self.framesFor(group)
        frames["a.jpg"] = (preview: "g07_p01.jpg", faces: "g07_p01_faces.jpg")
        let message = CullPromptBuilder.userMessage(
            group: group, index: 1, count: 1,
            tokens: CullPromptBuilder.tokens(for: group),
            frames: frames
        )
        #expect(message.contains("p01: g07_p01.jpg (faces: g07_p01_faces.jpg)"))
    }

    @Test func userMessageHasNoAbsolutePaths() {
        let group = Self.burstGroup()
        let message = CullPromptBuilder.userMessage(
            group: group, index: 1, count: 1,
            tokens: CullPromptBuilder.tokens(for: group),
            frames: Self.framesFor(group)
        )
        #expect(!message.contains("/Users"))
        #expect(!message.contains("file://"))
        let words = message.split(whereSeparator: \.isWhitespace)
        #expect(!words.contains { $0.hasPrefix("/") })
    }
}
