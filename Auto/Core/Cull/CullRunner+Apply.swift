import Foundation

/// The last step of a run: move the rejects, or put everything back when the move is stopped or fails.
nonisolated extension CullRunner {

    /// Builds the run's summary from (rejected count, undone).
    typealias SummaryMaker = @Sendable (Int, Bool) -> CullRunSummary

    func applyUnderLock(
        _ plan: CullPlan,
        rejectCount: Int,
        copies: [URL],
        cardVolumes: [URL],
        withApplyLock: @escaping ApplyLock,
        tracker: CullProgressTracker,
        summary: @escaping SummaryMaker
    ) async -> CullOutcome {
        let result = ApplyResult()
        let applier = self.applier
        let runID = plan.runID
        do {
            try await withApplyLock {
                if Task.isCancelled {
                    result.set(.stopped(nil))
                    return
                }
                tracker.set(.applying(done: 0, total: rejectCount), CullProgressScale.applyStart)

                var applyError: Error?
                var moved = 0
                do {
                    moved = try applier.apply(plan, copies: copies, cardVolumes: cardVolumes) { done, total in
                        tracker.set(.applying(done: done, total: total),
                                    CullProgressScale.applyStart + CullProgressScale.applySpan * cullRatio(done, total))
                    }
                } catch {
                    applyError = error
                }

                let cancelled = Task.isCancelled || applyError is CancellationError
                guard cancelled || applyError != nil else {
                    tracker.set(.applying(done: moved, total: moved), 1)
                    result.set(.completed(summary(moved, false)))
                    return
                }

                // Revert must complete, so it runs in a task that is never cancelled.
                let revertError: Error? = await Task.detached {
                    do {
                        try applier.revert(runID: runID, copies: copies, cardVolumes: cardVolumes) { done, total in
                            tracker.setRaw(.reverting(done: done, total: total),
                                           CullProgressScale.applyStart * (1 - cullRatio(done, total)))
                        }
                        return nil
                    } catch {
                        return error
                    }
                }.value

                if cancelled {
                    // "Nothing to undo" just means the stop came before anything moved.
                    let nothingWasMoved = (revertError as? CullError) == .nothingToUndo
                    if let revertError, !nothingWasMoved {
                        result.set(.failed(Self.cullError(revertError), nil))
                    } else {
                        result.set(.stopped(summary(rejectCount, true)))
                    }
                } else if let applyError {
                    result.set(.failed(Self.cullError(applyError), nil))
                }
            }
        } catch {
            if result.value == nil {
                let stopped = Task.isCancelled || error is CancellationError
                return stopped ? .stopped(nil) : .failed(Self.cullError(error), nil)
            }
        }
        return result.value ?? .stopped(nil)
    }

    private static func cullError(_ error: Error) -> CullError {
        (error as? CullError) ?? .journalWriteFailed(error.localizedDescription)
    }
}

/// Carries the outcome out of the apply-lock closure.
private nonisolated final class ApplyResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: CullOutcome?
    var value: CullOutcome? { lock.withLock { _value } }
    func set(_ newValue: CullOutcome) { lock.withLock { _value = newValue } }
}
