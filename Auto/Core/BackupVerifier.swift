import CryptoKit
import Foundation

nonisolated enum VerifyResult: Sendable, Equatable {
    /// A drive copy with identical content (checksum match).
    case verified(URL)
    /// Same-name, same-size files exist on the drive, but none has the same content.
    case mismatch
    /// Nothing on the drive shares the file's name and size.
    case missing

    var isVerified: Bool { if case .verified = self { true } else { false } }
}

/// Session-lifetime record of drive copies already proven identical to a card file.
/// Keyed by card file identity (card volume + full path + size + mtime) + drive path + drive mtime,
/// so another card's same-name file never matches and an edited drive file is re-hashed.
nonisolated final class VerificationCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = Set<String>()

    private static func entry(_ file: MediaFile, _ candidate: URL, _ mtime: Date) -> String {
        "\(file.identity)|\(candidate.standardizedFileURL.path)|\(mtime.timeIntervalSince1970)"
    }

    static func modificationDate(_ url: URL) -> Date? {
        // attributesOfItem, not URL.resourceValues: URL objects cache resource values.
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    func record(_ file: MediaFile, candidate: URL, mtime: Date) {
        lock.lock(); entries.insert(Self.entry(file, candidate, mtime)); lock.unlock()
    }

    /// Records files CopyEngine just copied and checksum-verified, against their exact destination.
    func record(_ copied: [CopiedFile]) {
        for c in copied {
            if let mtime = c.destinationModified { record(c.file, candidate: c.destination, mtime: mtime) }
        }
    }

    /// The first candidate that is still recorded as identical (and unchanged since).
    func verifiedCandidate(for file: MediaFile, in candidates: [URL]) -> URL? {
        lock.lock(); defer { lock.unlock() }
        for url in candidates {
            guard let mtime = Self.modificationDate(url) else { continue }
            if entries.contains(Self.entry(file, url, mtime)) { return url }
        }
        return nil
    }
}

nonisolated struct VerifyOutcome: Sendable {
    var results: [URL: VerifyResult] = [:]
    var cancelled = false
}

/// Decides, per card file, whether a byte-identical copy exists on the work drive.
/// Name + size only nominate candidates; only a checksum match counts. Read-only everywhere.
nonisolated final class BackupVerifier: @unchecked Sendable {
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

    /// Test hook, called synchronously on the verify thread after each chunk. Set before `run`.
    var onChunkHashed: (@Sendable (Int64) -> Void)?

    private static let chunk = 8 << 20

    /// Splits card files before any hashing: files with no candidate are missing, cached ones are
    /// verified, the rest need a checksum pass. There is no name+size shortcut: a file only counts
    /// as verified through a checksum, either now or recorded in `cache` for this exact card file.
    static func triage(
        files: [MediaFile],
        candidates: [String: [URL]],
        cache: VerificationCache? = nil
    ) -> (settled: [URL: VerifyResult], toVerify: [MediaFile]) {
        var settled: [URL: VerifyResult] = [:]
        var toVerify: [MediaFile] = []
        for file in files {
            let list = candidates[file.key] ?? []
            if let hit = cache?.verifiedCandidate(for: file, in: list) {
                settled[file.url] = .verified(hit)
            } else if list.isEmpty {
                settled[file.url] = .missing
            } else {
                toVerify.append(file)
            }
        }
        return (settled, toVerify)
    }

    /// `triage` without blocking the caller: the cache lookup stats every candidate on disk.
    @concurrent static func triageOffMain(
        files: [MediaFile],
        candidates: [String: [URL]],
        cache: VerificationCache?
    ) async -> (settled: [URL: VerifyResult], toVerify: [MediaFile]) {
        triage(files: files, candidates: candidates, cache: cache)
    }

    /// Hashes each card file once, then candidates in order until one matches. Runs off the main
    /// thread; progress arrives on the main actor and nothing is delivered after this returns.
    func run(
        _ files: [MediaFile],
        candidates: [String: [URL]],
        cache: VerificationCache? = nil,
        onProgress: @escaping @MainActor @Sendable (CopyProgress) -> Void
    ) async -> VerifyOutcome {
        let (stream, yield) = AsyncStream<CopyProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @MainActor in
            for await p in stream { onProgress(p) }
        }
        let outcome: VerifyOutcome = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: self.runSync(files, candidates: candidates, cache: cache) { _ = yield.yield($0) })
            }
        }
        yield.finish()
        await consumer.value
        return outcome
    }

    private func runSync(
        _ files: [MediaFile],
        candidates: [String: [URL]],
        cache: VerificationCache?,
        onProgress: @escaping @Sendable (CopyProgress) -> Void
    ) -> VerifyOutcome {
        var progress = CopyProgress(filesTotal: files.count, bytesTotal: files.reduce(0) { $0 + $1.size })
        var outcome = VerifyOutcome()
        var lastReport = Date.distantPast
        let report: (Bool) -> Void = { force in
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                onProgress(progress)
            }
        }

        for file in files {
            if isCancelled { outcome.cancelled = true; break }
            progress.currentFile = file.name
            report(true)
            let startBytes = progress.bytesDone
            do {
                let result = try verify(file, candidates: candidates[file.key] ?? [], cache: cache) { read in
                    progress.bytesDone = startBytes + min(read, file.size)
                    report(false)
                }
                outcome.results[file.url] = result
            } catch VerifyError.cancelled {
                outcome.cancelled = true
                break
            } catch {
                // Unreadable card file: never claim it is backed up.
                outcome.results[file.url] = .mismatch
            }
            progress.bytesDone = startBytes + file.size
            progress.filesDone += 1
            report(true)
        }
        return outcome
    }

    enum VerifyError: Error, Sendable { case cancelled }

    private func verify(_ file: MediaFile, candidates: [URL], cache: VerificationCache?, onBytes: (Int64) -> Void) throws -> VerifyResult {
        if candidates.isEmpty { return .missing }
        let cardHash = try hash(file.url, onBytes: onBytes)
        for candidate in candidates {
            // mtime is read before hashing so a file edited mid-check can't be cached as verified.
            let mtime = VerificationCache.modificationDate(candidate)
            let size = (try? FileManager.default.attributesOfItem(atPath: candidate.path)[.size] as? Int64) ?? nil
            guard size == file.size else { continue }
            let candidateHash: Data
            do { candidateHash = try hash(candidate, onBytes: { _ in }) } catch VerifyError.cancelled { throw VerifyError.cancelled } catch { continue }
            if candidateHash == cardHash {
                if let mtime { cache?.record(file, candidate: candidate, mtime: mtime) }
                return .verified(candidate)
            }
        }
        return .mismatch
    }

    /// MD5 in chunks. F_NOCACHE so we hash what is on disk, and don't evict the page cache with footage.
    private func hash(_ url: URL, onBytes: (Int64) -> Void) throws -> Data {
        var md5 = Insecure.MD5()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        var read: Int64 = 0
        while true {
            if isCancelled { throw VerifyError.cancelled }
            let data: Data? = try autoreleasepool { try handle.read(upToCount: Self.chunk) }
            guard let data, !data.isEmpty else { break }
            md5.update(data: data)
            read += Int64(data.count)
            onBytes(read)
            onChunkHashed?(read)
        }
        return Data(md5.finalize())
    }

    /// Adds copy destinations to a name+size candidate index (no duplicates). They are still only
    /// candidates; the cache or a checksum pass decides whether they count.
    static func addingCandidates(_ copied: [CopiedFile], to candidates: [String: [URL]]) -> [String: [URL]] {
        var result = candidates
        for c in copied {
            // The card file's key, not the destination name: a renamed copy ("A001 2.ARW") still counts.
            let key = c.file.key
            if !(result[key] ?? []).contains(c.destination) { result[key, default: []].append(c.destination) }
        }
        return result
    }

    /// Card files that still need copying: everything not verified.
    static func missing(files: [MediaFile], results: [URL: VerifyResult]) -> [MediaFile] {
        files.filter { results[$0.url]?.isVerified != true }
    }
}
