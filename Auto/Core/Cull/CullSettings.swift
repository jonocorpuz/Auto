import Foundation

/// Claude model alias used for a cull. rawValue is the CLI alias.
nonisolated enum CullModel: String, Sendable, Codable, CaseIterable {
    case haiku, sonnet, opus
}

nonisolated struct CullSettings: Sendable, Codable, Equatable {
    var criteria: Set<String>
    var mode: CullMode
    var model: CullModel
    /// Custom run prompts keyed by `CullMode.rawValue`; a missing or empty entry = generated.
    var customPrompts: [String: String]
    /// UI only; has no effect on applying decisions.
    var reviewBeforeApplying: Bool
    /// 1...4, clamped.
    var maxConcurrentCalls: Int
    var maxRunBudgetUSD: Double

    init(
        criteria: Set<String> = Set(CullCriterion.all.map(\.id)),
        mode: CullMode = .balanced,
        model: CullModel = .sonnet,
        customPrompts: [String: String] = [:],
        reviewBeforeApplying: Bool = false,
        maxConcurrentCalls: Int = 2,
        maxRunBudgetUSD: Double = 10
    ) {
        self.criteria = criteria
        self.mode = mode
        self.model = model
        self.customPrompts = customPrompts
        self.reviewBeforeApplying = reviewBeforeApplying
        self.maxConcurrentCalls = maxConcurrentCalls
        self.maxRunBudgetUSD = maxRunBudgetUSD
    }

    func customPrompt(for mode: CullMode) -> String? {
        guard let p = customPrompts[mode.rawValue], !p.isEmpty else { return nil }
        return p
    }

    mutating func setCustomPrompt(_ prompt: String?, for mode: CullMode) {
        if let prompt, !prompt.isEmpty {
            customPrompts[mode.rawValue] = prompt
        } else {
            customPrompts[mode.rawValue] = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case criteria, mode, model, customPrompts, reviewBeforeApplying, maxConcurrentCalls, maxRunBudgetUSD
    }

    /// Legacy keys, read only.
    private enum LegacyKeys: String, CodingKey {
        case aggressiveness, customRunPrompt
    }

    /// Tolerates older or partial JSON: every missing key takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let defaults = CullSettings()
        self.criteria = try c.decodeIfPresent(Set<String>.self, forKey: .criteria) ?? defaults.criteria
        self.customPrompts = try c.decodeIfPresent([String: String].self, forKey: .customPrompts) ?? [:]
        if let mode = try c.decodeIfPresent(CullMode.self, forKey: .mode) {
            self.mode = mode
        } else if let level = try legacy.decodeIfPresent(Int.self, forKey: .aggressiveness) {
            let migrated = CullMode.migrated(fromAggressiveness: level)
            self.mode = migrated
            if let old = try legacy.decodeIfPresent(String.self, forKey: .customRunPrompt), !old.isEmpty,
               customPrompts[migrated.rawValue] == nil {
                customPrompts[migrated.rawValue] = old
            }
        } else {
            self.mode = defaults.mode
        }
        self.model = try c.decodeIfPresent(CullModel.self, forKey: .model) ?? defaults.model
        self.reviewBeforeApplying = try c.decodeIfPresent(Bool.self, forKey: .reviewBeforeApplying) ?? defaults.reviewBeforeApplying
        self.maxConcurrentCalls = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentCalls) ?? defaults.maxConcurrentCalls
        var budget = try c.decodeIfPresent(Double.self, forKey: .maxRunBudgetUSD) ?? defaults.maxRunBudgetUSD
        if budget == 5.0 { budget = 10 }   // the old default
        self.maxRunBudgetUSD = budget
        self = clamped()
    }

    /// Returns a copy with numeric fields pulled into their supported ranges.
    func clamped() -> CullSettings {
        var s = self
        s.maxConcurrentCalls = min(max(s.maxConcurrentCalls, 1), 4)
        s.maxRunBudgetUSD = s.maxRunBudgetUSD.isNaN ? CullSettings().maxRunBudgetUSD : max(s.maxRunBudgetUSD, 0.1)
        return s
    }
}
