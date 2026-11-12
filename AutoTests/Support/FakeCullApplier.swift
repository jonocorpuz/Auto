import Foundation
@testable import Auto

/// Records plans and reverts. `waitForCancelInApply` blocks inside `apply` until the
/// surrounding task is cancelled (the real applier checks cancellation between pairs).
nonisolated final class FakeCullApplier: CullApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var _plans: [CullPlan] = []
    private var _reverts: [UUID] = []
    private var _applyStarted = false
    private var _revertWasCancelled: [Bool] = []
    private var _applyOnMain: [Bool] = []
    private let waitForCancelInApply: Bool

    init(waitForCancelInApply: Bool = false) {
        self.waitForCancelInApply = waitForCancelInApply
    }

    var plans: [CullPlan] { lock.withLock { _plans } }
    var reverts: [UUID] { lock.withLock { _reverts } }
    /// `Thread.isMainThread` at each `apply` call.
    var applyOnMainThread: [Bool] { lock.withLock { _applyOnMain } }
    var applyStarted: Bool { lock.withLock { _applyStarted } }
    var revertWasCancelled: [Bool] { lock.withLock { _revertWasCancelled } }

    func apply(_ plan: CullPlan, copies: [URL], cardVolumes: [URL], onMoved: @escaping @Sendable (Int, Int) -> Void) throws -> Int {
        lock.withLock { _plans.append(plan); _applyStarted = true; _applyOnMain.append(Thread.isMainThread) }
        if waitForCancelInApply {
            let deadline = Date().addingTimeInterval(10)
            while !Task.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if Task.isCancelled { throw CancellationError() }
        }
        let rejects = plan.decisions.filter { $0.verdict == .reject }.count
        onMoved(rejects, rejects)
        return rejects
    }

    func revert(runID: UUID, copies: [URL], cardVolumes: [URL], onProgress: @escaping @Sendable (Int, Int) -> Void) throws {
        lock.withLock { _reverts.append(runID); _revertWasCancelled.append(Task.isCancelled) }
        onProgress(1, 1)
    }
}
