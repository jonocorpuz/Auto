import CryptoKit
import Foundation

nonisolated struct CopyJob: Sendable {
    let file: MediaFile
    let destDir: URL
}

nonisolated struct CopyProgress: Sendable {
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var currentFile = ""

    var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }
}

nonisolated struct CopyOutcome: Sendable {
    var copiedKeys: [String] = []
    var failures: [(name: String, reason: String)] = []
    var cancelled = false
}

/// Copies files one at a time, hashing the card as it reads, then re-reads the copy
/// from the destination and only keeps it if the hashes match.
nonisolated final class CopyEngine: @unchecked Sendable {
    init() {}

    private let lock = NSLock()
    private var _cancelled = false
    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    private static let chunk = 8 << 20

    func run(_ jobs: [CopyJob], onProgress: @escaping @MainActor @Sendable (CopyProgress) -> Void) async -> CopyOutcome {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: self.runSync(jobs, onProgress: onProgress))
            }
        }
    }

    private func runSync(_ jobs: [CopyJob], onProgress: @escaping @MainActor @Sendable (CopyProgress) -> Void) -> CopyOutcome {
        var progress = CopyProgress(filesTotal: jobs.count, bytesTotal: jobs.reduce(0) { $0 + $1.file.size })
        var outcome = CopyOutcome()
        var lastReport = Date.distantPast

        let report: (Bool) -> Void = { force in
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                let snapshot = progress
                Task { @MainActor in onProgress(snapshot) }
            }
        }

        for job in jobs {
            if isCancelled { outcome.cancelled = true; break }
            progress.currentFile = job.file.name
            report(true)
            let startBytes = progress.bytesDone
            do {
                try FileManager.default.createDirectory(at: job.destDir, withIntermediateDirectories: true)
                try copyVerified(job) { written in
                    progress.bytesDone = startBytes + written
                    report(false)
                }
                outcome.copiedKeys.append(job.file.key)
            } catch CopyError.cancelled {
                outcome.cancelled = true
                break
            } catch {
                outcome.failures.append((job.file.name, error.localizedDescription))
            }
            progress.bytesDone = startBytes + job.file.size
            progress.filesDone += 1
            report(true)
        }
        return outcome
    }

    enum CopyError: LocalizedError, Sendable {
        case cancelled
        case mismatch
        case sizeMismatch

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Stopped"
            case .mismatch: return "Checksum didn't match the card"
            case .sizeMismatch: return "Copied size didn't match the card"
            }
        }
    }

    private func copyVerified(_ job: CopyJob, onBytes: (Int64) -> Void) throws {
        let fm = FileManager.default
        let source = job.file.url
        var dest = job.destDir.appendingPathComponent(job.file.name)

        // Already there from an earlier run? Keep it if it's byte-identical.
        if fm.fileExists(atPath: dest.path) {
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            if size == job.file.size, try hash(source) == hash(dest) {
                onBytes(job.file.size)
                return
            }
            dest = Self.uniqueURL(for: dest)
        }

        // Unique, exclusively-created partial: never touches anyone else's file.
        let partial = job.destDir.appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString).auto-partial")
        let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }

        do {
            var sourceHash = Insecure.MD5()
            var written: Int64 = 0
            let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let reader = try FileHandle(forReadingFrom: source)
            defer { try? reader.close(); try? writer.close() }
            while true {
                if isCancelled { throw CopyError.cancelled }
                let data: Data? = try autoreleasepool { try reader.read(upToCount: Self.chunk) }
                guard let data, !data.isEmpty else { break }
                sourceHash.update(data: data)
                try writer.write(contentsOf: data)
                written += Int64(data.count)
                onBytes(written)
            }
            // Force data to the platter, not just the cache; fall back if unsupported.
            if fcntl(fd, F_FULLFSYNC) == -1 { try writer.synchronize() }

            guard written == job.file.size else { throw CopyError.sizeMismatch }
            guard try hash(partial, bypassCache: true) == Data(sourceHash.finalize()) else { throw CopyError.mismatch }

            let attrs = try? fm.attributesOfItem(atPath: source.path)
            var keep: [FileAttributeKey: Any] = [:]
            if let created = attrs?[.creationDate] { keep[.creationDate] = created }
            if let modified = attrs?[.modificationDate] { keep[.modificationDate] = modified }
            try? fm.setAttributes(keep, ofItemAtPath: partial.path)
            _ = try Self.moveWithoutOverwriting(partial, to: dest)
        } catch {
            // Any failure after the partial exists (I/O, cancel, verify, rename) removes it.
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// `bypassCache` reads with F_NOCACHE so verification checks what is on disk.
    private func hash(_ url: URL, bypassCache: Bool = false) throws -> Data {
        var md5 = Insecure.MD5()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if bypassCache { _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1) }
        var read: Int64 = 0
        while true {
            if isCancelled { throw CopyError.cancelled }
            let data: Data? = try autoreleasepool { try handle.read(upToCount: Self.chunk) }
            guard let data, !data.isEmpty else { break }
            md5.update(data: data)
            read += Int64(data.count)
            if bypassCache { onVerifyChunk?(read) }
        }
        return Data(md5.finalize())
    }

    /// Atomically renames `src` to `dest` only if `dest` doesn't exist (RENAME_EXCL).
    /// On collision picks the next free name and retries (bounded). Returns the final URL.
    static func moveWithoutOverwriting(_ src: URL, to dest: URL, maxAttempts: Int = 100) throws -> URL {
        var target = dest
        for _ in 0..<maxAttempts {
            if renamex_np(src.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            let err = errno
            guard err == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSFilePathErrorKey: target.path])
            }
            target = uniqueURL(for: target)
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dest.path])
    }

    static func uniqueURL(for url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
