import Foundation

/// How views word a copy's progress.
nonisolated extension CopyProgress {
    /// The 1-based number of the file being worked on, never past the total.
    var currentFileNumber: Int {
        min(filesDone + 1, filesTotal)
    }

    /// "3 of 10 · 1.2 GB of 4 GB".
    var filesAndBytesText: String {
        "\(currentFileNumber) of \(filesTotal) · \(Format.bytes(bytesDone)) of \(Format.bytes(bytesTotal))"
    }
}
