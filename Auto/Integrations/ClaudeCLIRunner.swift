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
        for key in env.keys where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_") || key == "CLAUDECODE" {
            env.removeValue(forKey: key)
        }
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        if let path = env["PATH"], !path.isEmpty {
            env["PATH"] = path.contains("/opt/homebrew/bin") ? path : extra + ":" + path
        } else {
            env["PATH"] = extra + ":/usr/bin:/bin"
        }

        let job = Job()
        let timeoutTask = Task {
            try await Task.sleep(for: r.timeout)
            job.kill(.timedOut)
        }
        defer { timeoutTask.cancel() }

        let result = try await withTaskCancellationHandler {
            try await job.execute(exe: exe, arguments: ClaudeCLI.arguments(for: r), environment: env,
                                  cwd: r.workspace, stdin: Data(r.userPrompt.utf8))
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
        if let found { cachedLookup = found }  // never cache nil or a timeout
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
//
// Uses posix_spawn (not Process) so the child gets its own process group (POSIX_SPAWN_SETPGROUP):
// cancel/timeout signal the whole group, which also takes down grandchildren.

private nonisolated enum KillReason: Sendable { case timedOut, cancelled }

private nonisolated struct JobResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private nonisolated final class Job: @unchecked Sendable {
    private let lock = NSLock()
    private var _reason: KillReason?
    private var pid: pid_t = 0
    private var reaped = false
    private var abandoned = false
    private var cont: CheckedContinuation<JobResult, Error>?
    private var finished = false

    var reason: KillReason? {
        lock.lock(); defer { lock.unlock() }
        return _reason
    }

    private var isAbandoned: Bool {
        lock.lock(); defer { lock.unlock() }
        return abandoned
    }

    func kill(_ why: KillReason) {
        lock.lock()
        if _reason == nil { _reason = why }
        abandoned = true
        let target = (pid > 0 && !reaped) ? pid : 0
        lock.unlock()
        if target > 0 {
            killpg(target, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _ = killpg(target, SIGKILL) }
        }
        finish(.success(JobResult(status: -1, stdout: Data(), stderr: Data())))
    }

    /// Resume-once: only the first call resumes the continuation.
    private func finish(_ result: Result<JobResult, Error>) {
        lock.lock()
        let c = finished ? nil : cont
        finished = true
        cont = nil
        lock.unlock()
        c?.resume(with: result)
    }

    func execute(exe: URL, arguments: [String], environment: [String: String],
                 cwd: URL, stdin: Data) async throws -> JobResult {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<JobResult, Error>) in
            start(exe: exe, arguments: arguments, environment: environment, cwd: cwd, stdin: stdin, cont: c)
        }
    }

    private func start(exe: URL, arguments: [String], environment: [String: String], cwd: URL,
                       stdin: Data, cont c: CheckedContinuation<JobResult, Error>) {
        var open: [Int32] = []
        func closeAll() { for fd in open { close(fd) }; open = [] }
        let inR: Int32, inW: Int32, outR: Int32, outW: Int32, errR: Int32, errW: Int32
        do {
            (inR, inW) = try Self.makePipe(); open += [inR, inW]
            (outR, outW) = try Self.makePipe(); open += [outR, outW]
            (errR, errW) = try Self.makePipe(); open += [errR, errW]
        } catch {
            closeAll()
            c.resume(throwing: error)
            return
        }
        _ = fcntl(inW, F_SETNOSIGPIPE, 1)  // a child that exits early must not SIGPIPE us

        lock.lock()
        if let why = _reason {
            lock.unlock()
            closeAll()
            c.resume(throwing: why == .timedOut ? ClaudeRunnerError.timedOut : CancellationError())
            return
        }
        let child: pid_t
        do {
            child = try Self.spawn(exe: exe, arguments: arguments, environment: environment, cwd: cwd,
                                   stdinFD: inR, stdoutFD: outW, stderrFD: errW)
        } catch {
            lock.unlock()
            closeAll()
            c.resume(throwing: error)
            return
        }
        pid = child
        cont = c
        lock.unlock()

        close(inR); close(outW); close(errW)

        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        for (fd, box) in [(outR, outBox), (errR, errBox)] {
            group.enter()
            Thread.detachNewThread { [self] in
                box.set(readAll(fd))
                group.leave()
            }
        }
        Thread.detachNewThread {
            Self.writeAll(inW, stdin)
        }
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) < 0 && errno == EINTR {}
            lock.lock()
            reaped = true
            let why = _reason
            lock.unlock()
            if why != nil { return }  // kill() already finished the call

            // Orphaned grandchildren may keep the pipes open; give them a moment, then cut them loose.
            if group.wait(timeout: .now() + 1) == .timedOut {
                lock.lock(); abandoned = true; lock.unlock()
                _ = killpg(child, SIGKILL)
                _ = group.wait(timeout: .now() + 1)
            }
            let status: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : raw & 0x7f
            finish(.success(JobResult(status: status, stdout: outBox.get(), stderr: errBox.get())))
        }
    }

    private func readAll(_ fd: Int32) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while !isAbandoned {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 100)
            if r < 0 { if errno == EINTR { continue }; break }
            if r == 0 { continue }
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(buf, count: n) }
            else if n == 0 { break }
            else if errno == EINTR || errno == EAGAIN { continue }
            else { break }
        }
        close(fd)
        return out
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }
                break  // EPIPE (child gone) or other error: benign
            }
        }
        close(fd)
    }

    private static func makePipe() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    private static func spawn(exe: URL, arguments: [String], environment: [String: String], cwd: URL,
                              stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32) throws -> pid_t {
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, stdinFD, 0)
        posix_spawn_file_actions_adddup2(&fa, stdoutFD, 1)
        posix_spawn_file_actions_adddup2(&fa, stderrFD, 2)
        posix_spawn_file_actions_addchdir(&fa, cwd.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGPIPE, SIGINT, SIGTERM, SIGQUIT, SIGHUP] { sigaddset(&defaults, s) }
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv: [UnsafeMutablePointer<CChar>?] = ([exe.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let rc = posix_spawn(&child, exe.path, &fa, &attr, argv, envp)
        guard rc == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc)) }
        return child
    }
}

private nonisolated final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
