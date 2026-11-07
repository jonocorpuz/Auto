import Foundation
import Testing
@testable import Auto

struct SelectsPlannerTests {

    private func cand(_ id: String, _ score: Int, _ tie: Double = 0) -> SelectsPlanner.Candidate {
        .init(photoID: id, score: score, tiebreak: tie)
    }

    @Test func targetCount() {
        let expected = [(0, 0), (1, 1), (9, 1), (10, 1), (11, 2), (500, 50)]
        for (n, t) in expected { #expect(SelectsPlanner.targetCount(photoCount: n) == t) }
    }

    @Test func poolSizeIsTwoAndAHalfTimesTarget() {
        #expect(SelectsPlanner.poolSize(target: 50) == 125)
        #expect(SelectsPlanner.poolSize(target: 1) == 3)
        #expect(SelectsPlanner.poolSize(target: 3) == 8)
    }

    @Test func poolSortsWithDeterministicTieBreaks() {
        let all = [cand("c", 5, 0.1), cand("a", 5, 0.1), cand("b", 5, 0.9), cand("d", 9), cand("e", 1)]
        let pool = SelectsPlanner.pool(from: all, target: 1) // poolSize 3
        #expect(pool.map(\.photoID) == ["d", "b", "a"])
    }

    @Test func snakeBatchesAreBalanced() {
        let all = (0..<30).map { cand("p\($0)", 30 - $0) }
        let batches = SelectsPlanner.batches(all, size: 10)
        #expect(batches.count == 3)
        #expect(batches.flatMap { $0 }.count == 30)
        let sums = batches.map { $0.map(\.score).reduce(0, +) }
        #expect(sums.max()! - sums.min()! <= 2)
        #expect(SelectsPlanner.batches([], size: 10).isEmpty)
    }

    @Test func roundPlanEndsAtTargetAndFits() {
        for (pool, target) in [(125, 50), (25, 10), (3, 1), (8, 3), (25, 5), (250, 4)] {
            let plan = SelectsPlanner.roundPlan(poolCount: pool, target: target, batchSize: 10)
            #expect(plan.last == target)
            var prev = pool
            for n in plan { #expect(n < prev); prev = n }
            if plan.count >= 2 { #expect(plan[plan.count - 2] <= 10) }
        }
        #expect(SelectsPlanner.roundPlan(poolCount: 5, target: 5, batchSize: 10).isEmpty)
        #expect(SelectsPlanner.roundPlan(poolCount: 4, target: 5, batchSize: 10).isEmpty)
    }

    @Test func quotaIsProportionalCeilAtLeastOne() {
        #expect(SelectsPlanner.quota(batch: 10, survivorsBefore: 25, survivorsAfter: 10) == 4)
        #expect(SelectsPlanner.quota(batch: 1, survivorsBefore: 100, survivorsAfter: 1) == 1)
    }

    @Test func mergeHandlesBadPicks() {
        let batch = [cand("a", 9), cand("b", 7), cand("c", 5), cand("d", 3)]
        #expect(SelectsPlanner.merge(picks: ["c", "zzz", "c", "a"], batch: batch, quota: 2).map(\.photoID) == ["c", "a"])
        #expect(SelectsPlanner.merge(picks: ["d"], batch: batch, quota: 3).map(\.photoID) == ["d", "a", "b"])
        #expect(SelectsPlanner.merge(picks: ["d", "c", "b", "a"], batch: batch, quota: 2).map(\.photoID) == ["d", "c"])
        #expect(SelectsPlanner.merge(picks: [], batch: batch, quota: 2).map(\.photoID) == ["a", "b"])
    }

    @Test func trimCutsByRank() {
        let s = [cand("a", 3), cand("b", 9), cand("c", 5)]
        #expect(SelectsPlanner.trim(s, to: 2).map(\.photoID) == ["b", "c"])
        #expect(SelectsPlanner.trim(s, to: 0).isEmpty)
    }
}
