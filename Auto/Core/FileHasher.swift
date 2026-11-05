import CryptoKit
import Foundation

/// Cancellable MD5 hasher: 8 MB chunks, F_NOCACHE so we hash what is on disk and don't evict the
/// page cache with footage. Read-only. Standalone on purpose: it mirrors the private hashers in
/// CopyEngine and BackupVerifier (duplication noted; merging them is a backlog refactor).
nonisolated final class FileHasher: @unchecked Sendable {
    struct Cancelled: Error, Sendable {}

    init() {}

    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    /// Test hook, called synchronously on the hashing thread after each chunk with bytes read so far.
    var onChunkHashed: (@Sendable (Int64) -> Void)?

    /// Test hook, called on the hashing thread each time a whole file has been hashed.
    var onFileHashed: (@Sendable (URL) -> Void)?

    static let chunk = 8 << 20

    /// MD5 of the file. `onBytes` receives the running byte count after each chunk.
    /// Throws `Cancelled` as soon as `cancel()` has been called.
    func md5(_ url: URL, onBytes: (Int64) -> Void) throws -> Data {
        var md5 = Insecure.MD5()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        var read: Int64 = 0
        while true {
            if isCancelled { throw Cancelled() }
            let data: Data? = try autoreleasepool { try handle.read(upToCount: Self.chunk) }
            guard let data, !data.isEmpty else { break }
            md5.update(data: data)
            read += Int64(data.count)
            onBytes(read)
            onChunkHashed?(read)
        }
        let digest = Data(md5.finalize())
        onFileHashed?(url)
        return digest
    }
}
