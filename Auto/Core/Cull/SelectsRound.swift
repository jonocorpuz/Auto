import Foundation

/// Pure planning for the Selects elimination rounds: pick a candidate pool,
/// deal it into balanced batches, and decide how many survive each round.
nonisolated enum SelectsPlanner {

    static let batchSize = 10
    static let keepFraction = CullMode.selectsKeepFraction
    static let poolMultiplier = 2.5

    struct Candidate: Sendable, Equatable {
        let photoID: String
        let score: Int
        let tiebreak: Double
        /// Milestone, group or celebration: ranked one point higher for the pool and batches.
        var keyMoment = false

        var rankScore: Int { score + (keyMoment ? 1 : 0) }
    }

    /// Score at or above which a frame counts as strong for the soft target.
    static let strongScore = 7
    static let minFraction = 0.10
    static let maxFraction = 0.20

    /// About `keepFraction` of the shoot. With `strongCount` (frames scoring `strongScore`+),
    /// the target moves halfway toward it, bounded to `minFraction...maxFraction`: a weak shoot
    /// gives fewer selects, a strong one more.
    static func targetCount(photoCount: Int, strongCount: Int? = nil) -> Int {
        guard photoCount > 0 else { return 0 }
        let n = Double(photoCount)
        var target = keepFraction * n
        if let strongCount {
            target = min(max((target + Double(strongCount)) / 2, minFraction * n), maxFraction * n)
        }
        return max(1, Int(target.rounded()))
    }

    static func poolSize(target: Int) -> Int {
        Int((poolMultiplier * Double(target)).rounded(.up))
    }

    private static func ranked(_ c: [Candidate]) -> [Candidate] {
        c.sorted {
            if $0.rankScore != $1.rankScore { return $0.rankScore > $1.rankScore }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.tiebreak != $1.tiebreak { return $0.tiebreak > $1.tiebreak }
            return $0.photoID < $1.photoID
        }
    }

    static func pool(from candidates: [Candidate], target: Int) -> [Candidate] {
        Array(ranked(candidates).prefix(poolSize(target: target)))
    }

    /// Snake-deals by rank (0,1,2,2,1,0,0,1,...) so each batch gets a balanced score spread.
    static func batches(_ candidates: [Candidate], size: Int) -> [[Candidate]] {
        guard !candidates.isEmpty, size > 0 else { return [] }
        let batchCount = (candidates.count + size - 1) / size
        var out = [[Candidate]](repeating: [], count: batchCount)
        for (rank, candidate) in ranked(candidates).enumerated() {
            let lap = rank / batchCount
            let positionInLap = rank % batchCount
            let dealsForward = lap % 2 == 0
            let batchIndex = dealsForward ? positionInLap : batchCount - 1 - positionInLap
            out[batchIndex].append(candidate)
        }
        return out
    }

    /// Survivors after each round; strictly decreasing, last == target.
    /// Uses a constant keep ratio (target/pool)^(1/rounds) with the minimal
    /// round count whose final round fits in one batch. When target >= batchSize
    /// that is impossible, so a single round straight to the target is used.
    /// Safety cap on the round search; real pools need only a handful.
    private static let maxRounds = 64

    static func roundPlan(poolCount: Int, target: Int, batchSize: Int) -> [Int] {
        guard target > 0, poolCount > target else { return [] }
        if target >= batchSize { return [target] }
        var rounds = 1
        while rounds < maxRounds {
            let ratio = pow(Double(target) / Double(poolCount), 1 / Double(rounds))
            let beforeFinal = Int((Double(poolCount) * pow(ratio, Double(rounds - 1))).rounded(.up))
            if beforeFinal <= batchSize { break }
            rounds += 1
        }
        let ratio = pow(Double(target) / Double(poolCount), 1 / Double(rounds))
        var plan: [Int] = []
        var prev = poolCount
        for r in 1..<max(rounds, 1) {
            let raw = Int((Double(poolCount) * pow(ratio, Double(r))).rounded(.up))
            let n = min(raw, prev - 1)
            if n <= target { break }
            plan.append(n)
            prev = n
        }
        plan.append(target)
        return plan
    }

    /// Per-batch quotas that sum exactly to `after` (when it fits): floor of the proportional share,
    /// then the remainder one each in batch order (batches arrive best-first), capped at batch size.
    static func quotas(batchSizes: [Int], survivorsAfter after: Int) -> [Int] {
        let total = batchSizes.reduce(0, +)
        guard total > 0 else { return batchSizes.map { _ in 0 } }
        let target = min(max(0, after), total)
        var out = batchSizes.map { $0 * target / total }
        var left = target - out.reduce(0, +)
        while left > 0 {
            var progressed = false
            for i in out.indices where left > 0 && out[i] < batchSizes[i] {
                out[i] += 1
                left -= 1
                progressed = true
            }
            if !progressed { break }
        }
        return out
    }

    static func merge(picks: [String], batch: [Candidate], quota: Int) -> [Candidate] {
        let byID = Dictionary(batch.map { ($0.photoID, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [Candidate] = []
        for id in picks {
            guard let c = byID[id], seen.insert(id).inserted else { continue }
            out.append(c)
        }
        if out.count < quota {
            for c in ranked(batch) where !seen.contains(c.photoID) {
                out.append(c)
                seen.insert(c.photoID)
                if out.count >= quota { break }
            }
        }
        return Array(out.prefix(quota))
    }

    static func trim(_ survivors: [Candidate], to n: Int) -> [Candidate] {
        Array(ranked(survivors).prefix(max(0, n)))
    }
}
