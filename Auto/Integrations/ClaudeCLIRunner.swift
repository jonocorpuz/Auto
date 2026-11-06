import Foundation

/// Runs the real `claude` CLI headlessly. See `ClaudeCLI` for the pure argument/parse helpers.
nonisolated final class ClaudeCLIRunner: ClaudeRunner, Sendable {
    private let executable: URL?
    private let environment: [String: String]

    private static let lookupLock = NSLock()
    nonisolated(unsafe) private static var cachedLookup: String??

    init(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.environment = environment
    }

    func run(_ r: ClaudeRequest) async throws -> ClaudeResponse {
        guard let exe = await resolveExecutable() else { throw ClaudeRunnerError.notInstalled }
        try Task.checkCancellation()

        var env = environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        if let path = env["PATH"], !path.isEmpty {
            env["PATH"] = path.contains("/opt/homebrew/bin") ? path : extra + ":" + path
        } else {
            env["PATH"] = extra + ":/usr/bin:/bin"
        }

        let process = Process()
        process.executableURL = exe
        process.arguments = ClaudeCLI.arguments(for: r)
        process.currentDirectoryURL = r.workspace
        process.environment = env

        let job = Job(process: process)
        let timeoutTask = Task {
            try await Task.sleep(for: r.timeout)
            job.kill(.timedOut)
        }
        defer { timeoutTask.cancel() }

        let result = try await withTaskCancellationHandler {
            try await job.execute(stdin: Data(r.userPrompt.utf8))
        } onCancel: {
            job.kill(.cancelled)
        }

        switch job.reason {
        case .timedOut: throw ClaudeRunnerError.timedOut
        case .cancelled: throw CancellationError()
        case nil: break
        }
        try Task.checkCancellation()

        if result.status == 0 { return try ClaudeCLI.parse(stdout: result.stdout) }
        if let parsed = try? ClaudeCLI.parse(stdout: result.stdout) { return parsed }
        let err = String(decoding: result.stderr, as: UTF8.self)
        throw ClaudeRunnerError.exit(result.status, String(err.suffix(500)))
    }

    // MARK: - Executable lookup

    private func resolveExecutable() async -> URL? {
        if let executable {
            return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
        }
        let env = environment
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: ClaudeCLI.locate(
                    env: env,
                    home: FileManager.default.homeDirectoryForCurrentUser,
                    fileExists: { FileManager.default.isExecutableFile(atPath: $0) },
                    loginShellLookup: { Self.loginShellLookup() }
                ))
            }
        }
    }

    private static func loginShellLookup() -> String? {
        lookupLock.lock()
        defer { lookupLock.unlock() }
        if let cached = cachedLookup { return cached }
        let found = runLookup()
        cachedLookup = .some(found)
        return found
    }

    private static func runLookup() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).last.map(String.init)
    }
}

// MARK: - Process job

private nonisolated enum KillReason: Sendable { case timedOut, cancelled }

private nonisolated struct JobResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private nonisolated final class Job: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var _reason: KillReason?
    private var started = false

    init(process: Process) { self.process = process }

    var reason: KillReason? {
        lock.lock(); defer { lock.unlock() }
        return _reason
    }

    func kill(_ why: KillReason) {
        lock.lock()
        if _reason == nil { _reason = why }
        let shouldKill = started
        lock.unlock()
        if shouldKill { terminateThenKill() }
    }

    private func terminateThenKill() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { Foundation.kill(pid, SIGKILL) }
        }
    }

    func execute(stdin: Data) async throws -> JobResult {
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JobResult, Error>) in
            let outBox = DataBox(), errBox = DataBox()
            let group = DispatchGroup()
            for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
                group.enter()
                DispatchQueue.global().async {
                    box.set((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
                    group.leave()
                }
            }
            process.terminationHandler = { [self] p in
                let status = p.terminationStatus
                let finish = { cont.resume(returning: JobResult(status: status, stdout: outBox.get(), stderr: errBox.get())) }
                if reason != nil {
                    // Orphaned grandchildren may keep the pipes open; don't wait on them.
                    finish()
                } else {
                    group.notify(queue: .global(), execute: finish)
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
                return
            }
            lock.lock()
            started = true
            let pending = _reason != nil
            lock.unlock()
            if pending { terminateThenKill() }

            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }
    }
}

private nonisolated final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
