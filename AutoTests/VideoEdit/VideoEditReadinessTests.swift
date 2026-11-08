import Foundation
import Testing
@testable import Auto

struct VideoEditReadinessTests {

    @Test func readyWhenEverythingIsOk() {
        let r = VideoEditReadiness.evaluate(videoCount: 12, mainCopyOnline: true, mcpRegistered: true, resolveRunning: true)
        #expect(r.isReady)
        #expect(r.blocker == nil)
        #expect(r.checks.map(\.id) == [.footage, .mainCopy, .mcp, .resolve])
        #expect(r.checks.allSatisfy { $0.hint == nil })
    }

    @Test func unknownInputsAreCheckingNotMissing() {
        let r = VideoEditReadiness.evaluate(videoCount: nil, mainCopyOnline: true, mcpRegistered: nil, resolveRunning: true)
        #expect(!r.isReady)
        #expect(r.checks[0].state == .checking && r.checks[0].hint == nil)
        #expect(r.checks[2].state == .checking)
    }

    @Test func blockerIsTheFirstProblemWithItsHint() {
        let r = VideoEditReadiness.evaluate(videoCount: 0, mainCopyOnline: false, mcpRegistered: false, resolveRunning: false)
        #expect(r.checks.allSatisfy { $0.state == .missing })
        #expect(r.blocker == "This shoot has no video clips.")
        let noResolve = VideoEditReadiness.evaluate(videoCount: 3, mainCopyOnline: true, mcpRegistered: true, resolveRunning: false)
        #expect(noResolve.blocker?.contains("resolve_bridge") == true)
        let noMCP = VideoEditReadiness.evaluate(videoCount: 3, mainCopyOnline: true, mcpRegistered: false, resolveRunning: true)
        #expect(noMCP.blocker == VideoEditReadiness.mcpMissingHint)
    }

    @Test func settingsRoundTripAndClampBudget() {
        let defaults = UserDefaults(suiteName: "VideoEditSettingsTests-\(UUID().uuidString)")!
        #expect(VideoEditSettingsStore.load(from: defaults) == VideoEditSettings())
        var s = VideoEditSettings()
        s.leaveOutAccidental = false
        s.model = .opus
        s.maxRunBudgetUSD = 500
        VideoEditSettingsStore.save(s, to: defaults)
        let loaded = VideoEditSettingsStore.load(from: defaults)
        #expect(loaded.leaveOutAccidental == false && loaded.model == .opus)
        #expect(loaded.maxRunBudgetUSD == VideoEditSettings.budgetRange.upperBound)
    }
}
