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
    }

    static func targetCount(photoCount: Int) -> Int {
        guard photoCount > 0 else { return 0 }
        return max(1, Int((keepFraction * Double(photoCount)).rounded(.up)))
    }

    static func poolSize(target: Int) -> Int {
        Int((poolMultiplier * Double(target)).rounded(.up))
    }

    private static func ranked(_ c: [Candidate]) -> [Candidate] {
        c.sorted {
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
        let count = (candidates.count + size - 1) / size
        var out = [[Candidate]](repeating: [], count: count)
        for (i, c) in ranked(candidates).enumerated() {
            let lap = i / count, pos = i % count
            out[lap % 2 == 0 ? pos : count - 1 - pos].append(c)
        }
        return out
    }

    /// Survivors after each round; strictly decreasing, last == target.
    /// Uses a constant keep ratio (target/pool)^(1/rounds) with the minimal
    /// round count whose final round fits in one batch. When target >= batchSize
    /// that is impossible, so a single round straight to the target is used.
    static func roundPlan(poolCount: Int, target: Int, batchSize: Int) -> [Int] {
        guard target > 0, poolCount > target else { return [] }
        if target >= batchSize { return [target] }
        var rounds = 1
        while rounds < 64 {
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

    /// Proportional share of the survivors for one batch, at least 1.
    static func quota(batch: Int, survivorsBefore: Int, survivorsAfter: Int) -> Int {
        guard survivorsBefore > 0 else { return 1 }
        let share = Double(batch) * Double(survivorsAfter) / Double(survivorsBefore)
        return max(1, Int(share.rounded(.up)))
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
