import CryptoKit
import Foundation
import os

nonisolated struct CopyJob: Sendable {
    let file: MediaFile
    let destDir: URL
    /// Copy root. When set, the engine refuses (`.rootMissing`) if it isn't a directory right now, and only
    /// creates folders BELOW it, one level at a time. nil = create `destDir` with intermediates.
    var root: URL? = nil
    var onCollision: CollisionPolicy = .renameUnique
    /// If set, the MD5 streamed from the source must equal this, else `.sourceChanged` and nothing is kept.
    var expectedChecksum: Data? = nil
    /// Requested file name in `destDir` (nil = the source's name). Only the requested name: a taken
    /// name still gets a unique sibling, never an overwrite. Must be one plain path component.
    var destName: String? = nil

    var requestedName: String { destName ?? file.name }
}

nonisolated enum CollisionPolicy: Sendable {
    /// A different file at the name gets a "name 2" sibling.
    case renameUnique
    /// A different file at the name fails the job with `.destinationExists`; nothing else is written.
    case skip
}

nonisolated struct CopyProgress: Sendable, Equatable {
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var currentFile = ""

    var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }
}

/// A card file that is now on the destination, proven identical by checksum.
nonisolated struct CopiedFile: Sendable, Equatable {
    let file: MediaFile
    /// Final destination file (after any unique renaming).
    let destination: URL
    /// Destination mtime read right after verification, for `VerificationCache`.
    let destinationModified: Date?
    /// An identical file was already there, so nothing was written.
    let preexisting: Bool
    /// MD5 of the source as read (equals the destination's, which was verified).
    var checksum: Data? = nil
}

nonisolated struct CopyOutcome: Sendable {
    struct Failure: Sendable {
        enum Kind: Sendable, Equatable {
            /// The bytes written or read did not check out (checksum or size mismatch, source changed).
            case integrity
            /// The destination could not take the file (missing root, no space, I/O, name taken).
            case destination
        }
        let name: String
        let reason: String
        let file: URL
        let root: URL?
        let kind: Kind
    }

    var copied: [CopiedFile] = []
    var copiedKeys: [String] { copied.map(\.file.key) }
    var failures: [Failure] = []
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

    /// Test hooks, called synchronously on the copy thread. Set before `run`.
    var onChunkWritten: (@Sendable (Int64) -> Void)?
    var onVerifyChunk: (@Sendable (Int64) -> Void)?

    private static let chunk = 8 << 20
    private static let log = Logger(subsystem: "Auto", category: "CopyEngine")

    func run(_ jobs: [CopyJob], onProgress: @escaping @MainActor @Sendable (CopyProgress) -> Void) async -> CopyOutcome {
        // Progress flows through a stream consumed on the main actor; `run` awaits the
        // consumer after finishing it, so no callback is delivered after `run` returns.
        let (stream, yield) = AsyncStream<CopyProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @MainActor in
            for await p in stream { onProgress(p) }
        }
        let outcome: CopyOutcome = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: self.runSync(jobs) { _ = yield.yield($0) })
            }
        }
        yield.finish()
        await consumer.value
        return outcome
    }

    private func runSync(_ jobs: [CopyJob], onProgress: @escaping @Sendable (CopyProgress) -> Void) -> CopyOutcome {
        var progress = CopyProgress(filesTotal: jobs.count, bytesTotal: jobs.reduce(0) { $0 + $1.file.size })
        var outcome = CopyOutcome()
        var lastReport = Date.distantPast

        let report: (Bool) -> Void = { force in
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                onProgress(progress)
            }
        }

        for job in jobs {
            if isCancelled { outcome.cancelled = true; break }
            progress.currentFile = job.file.name
            report(true)
            let startBytes = progress.bytesDone
            do {
                try Self.prepareDestination(job)
                let copied = try copyVerified(job) { written in
                    progress.bytesDone = startBytes + written
                    report(false)
                }
                outcome.copied.append(copied)
            } catch CopyError.cancelled {
                outcome.cancelled = true
                break
            } catch {
                let kind: CopyOutcome.Failure.Kind
                switch error as? CopyError {
                case .mismatch, .sizeMismatch, .sourceChanged: kind = .integrity
                default: kind = .destination
                }
                outcome.failures.append(.init(name: job.file.name, reason: error.localizedDescription, file: job.file.url,
                                              root: job.root, kind: kind))
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
        case destinationExists
        case sourceChanged
        case rootMissing
        case outsideRoot

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Stopped"
            case .mismatch: return "Checksum didn't match the card"
            case .sizeMismatch: return "Copied size didn't match the card"
            case .destinationExists: return "A different file is already at the destination"
            case .sourceChanged: return "The source file changed since it was last checked"
            case .rootMissing: return "The destination folder is missing"
            case .outsideRoot: return "The destination isn't a plain folder inside the copy folder"
            }
        }
    }

    /// Creates `destDir`. With a `root`, it must exist as a directory and only components below it are
    /// created, each without intermediates, so a vanished drive can never be recreated elsewhere.
    private static func prepareDestination(_ job: CopyJob) throws {
        let fm = FileManager.default
        guard let root = job.root else {
            try fm.createDirectory(at: job.destDir, withIntermediateDirectories: true)
            return
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { throw CopyError.rootMissing }
        let rootParts = root.standardizedFileURL.pathComponents
        let destParts = job.destDir.standardizedFileURL.pathComponents
        guard destParts.count >= rootParts.count, Array(destParts.prefix(rootParts.count)) == rootParts else {
            throw CopyError.outsideRoot
        }
        var current = root.standardizedFileURL
        for part in destParts.dropFirst(rootParts.count) {
            current.appendPathComponent(part, isDirectory: true)
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CopyError.outsideRoot }
            if fm.fileExists(atPath: current.path, isDirectory: &isDir) {
                guard isDir.boolValue else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: current.path]) }
            } else {
                try fm.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }

    private func copyVerified(_ job: CopyJob, onBytes: (Int64) -> Void) throws -> CopiedFile {
        let fm = FileManager.default
        let source = job.file.url
        let name = job.requestedName
        // A destName is one plain component: never a path that could step out of destDir.
        if let requested = job.destName {
            guard !requested.isEmpty, !requested.hasPrefix("."), !requested.contains("/") else { throw CopyError.outsideRoot }
        }
        var dest = job.destDir.appendingPathComponent(name)

        // Already there from an earlier run? Keep it if it's byte-identical.
        if fm.fileExists(atPath: dest.path) {
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            let mtime = VerificationCache.modificationDate(dest)
            if size == job.file.size {
                let sourceDigest = try hash(source)
                if let expected = job.expectedChecksum, sourceDigest != expected { throw CopyError.sourceChanged }
                if sourceDigest == (try hash(dest, bypassCache: true)) {
                    onBytes(job.file.size)
                    return CopiedFile(file: job.file, destination: dest, destinationModified: mtime, preexisting: true, checksum: sourceDigest)
                }
            }
            if job.onCollision == .skip { throw CopyError.destinationExists }
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
                onChunkWritten?(written)
            }
            // Force data to the platter, not just the cache; fall back if unsupported.
            if fcntl(fd, F_FULLFSYNC) == -1 { try writer.synchronize() }

            let sourceDigest = Data(sourceHash.finalize())
            if let expected = job.expectedChecksum, sourceDigest != expected { throw CopyError.sourceChanged }
            guard written == job.file.size else { throw CopyError.sizeMismatch }
            guard try hash(partial, bypassCache: true) == sourceDigest else { throw CopyError.mismatch }

            let attrs = try? fm.attributesOfItem(atPath: source.path)
            var keep: [FileAttributeKey: Any] = [:]
            if let created = attrs?[.creationDate] { keep[.creationDate] = created }
            if let modified = attrs?[.modificationDate] { keep[.modificationDate] = modified }
            // Not fatal (the bytes are verified), but flat-layout photo pairing relies on mtimes.
            do { try fm.setAttributes(keep, ofItemAtPath: partial.path) } catch {
                Self.log.error("Could not keep dates on \(dest.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            let final: URL
            do {
                final = try Self.moveWithoutOverwriting(partial, to: dest, renameOnCollision: job.onCollision == .renameUnique)
            } catch CopyError.destinationExists {
                // Something appeared at the name mid-copy. If it is byte-identical, that is a success.
                guard try hash(dest, bypassCache: true) == sourceDigest else { throw CopyError.destinationExists }
                try? fm.removeItem(at: partial)
                return CopiedFile(file: job.file, destination: dest, destinationModified: VerificationCache.modificationDate(dest), preexisting: true, checksum: sourceDigest)
            }
            return CopiedFile(file: job.file, destination: final, destinationModified: VerificationCache.modificationDate(final), preexisting: false, checksum: sourceDigest)
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
    /// On collision picks the next free name and retries (bounded), or with `renameOnCollision: false`
    /// throws `.destinationExists` without touching anything. Returns the final URL.
    static func moveWithoutOverwriting(_ src: URL, to dest: URL, maxAttempts: Int = 100, renameOnCollision: Bool = true) throws -> URL {
        var target = dest
        for _ in 0..<maxAttempts {
            if renamex_np(src.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            let err = errno
            guard err == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSFilePathErrorKey: target.path])
            }
            guard renameOnCollision else { throw CopyError.destinationExists }
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
