import Foundation
@testable import Auto

final class FakeClaudeRunner: ClaudeRunner, @unchecked Sendable {
    typealias Handler = @Sendable (ClaudeRequest) -> Result<ClaudeResponse, Error>

    private let lock = NSLock()
    private let handler: Handler
    private let hang: Bool
    private let hangIf: (@Sendable (ClaudeRequest) -> Bool)?
    private var _requests: [ClaudeRequest] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _terminated = 0

    /// `hangIf` hangs only the requests it matches (until cancelled).
    init(hang: Bool = false, hangIf: (@Sendable (ClaudeRequest) -> Bool)? = nil, handler: @escaping Handler) {
        self.hang = hang
        self.hangIf = hangIf
        self.handler = handler
    }

    var requests: [ClaudeRequest] { lock.withLock { _requests } }
    var inFlight: Int { lock.withLock { _inFlight } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var terminated: Int { lock.withLock { _terminated } }

    func run(_ r: ClaudeRequest) async throws -> ClaudeResponse {
        lock.withLock {
            _requests.append(r)
            _inFlight += 1
            _maxInFlight = max(_maxInFlight, _inFlight)
        }
        defer { lock.withLock { _inFlight -= 1 } }

        if hang || hangIf?(r) == true {
            do {
                try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(3600))
                } onCancel: {
                    self.lock.withLock { self._terminated += 1 }
                }
            } catch {
                throw CancellationError()
            }
        }
        try Task.checkCancellation()
        return try handler(r).get()
    }
}
