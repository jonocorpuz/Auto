import Foundation

/// Builds a temp folder that mimics a Sony camera card. Call `cleanup()` when done.
nonisolated struct FixtureCard {
    let root: URL

    static let jpgDate = Date(timeIntervalSince1970: 1_700_000_000)
    static let arwDate = Date(timeIntervalSince1970: 1_700_100_000)
    static let clipDate = Date(timeIntervalSince1970: 1_699_900_000) // earliest

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("AutoFixtureCard-\(UUID().uuidString)", isDirectory: true)

        let dcim = root.appendingPathComponent("DCIM/100MSDCF", isDirectory: true)
        let clip = root.appendingPathComponent("PRIVATE/M4ROOT/CLIP", isDirectory: true)
        let thumbs = root.appendingPathComponent("PRIVATE/M4ROOT/THMBNL", isDirectory: true)
        for dir in [dcim, clip, thumbs] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        try write(Data(repeating: 0x11, count: 1_024), to: dcim.appendingPathComponent("DSC00001.JPG"), date: Self.jpgDate)
        try write(Data(repeating: 0x22, count: 4_096), to: dcim.appendingPathComponent("DSC00001.ARW"), date: Self.arwDate)
        try write(Data((0..<20_000).map { UInt8($0 % 251) }), to: clip.appendingPathComponent("C0001.MP4"), date: Self.clipDate)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <NonRealTimeMeta><Device manufacturer="Sony" modelName="ILME-FX3" serialNo="1234567"/></NonRealTimeMeta>
        """
        try write(Data(xml.utf8), to: clip.appendingPathComponent("C0001M01.XML"), date: Self.clipDate)
        try write(Data(repeating: 0x33, count: 128), to: thumbs.appendingPathComponent("C0001T01.JPG"), date: Self.jpgDate)
    }

    var dcim: URL { root.appendingPathComponent("DCIM/100MSDCF") }
    var clip: URL { root.appendingPathComponent("PRIVATE/M4ROOT/CLIP") }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private func write(_ data: Data, to url: URL, date: Date) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Makes an empty temp folder (e.g. a backup destination).
    static func makeTempDir(_ label: String = "AutoFixtureDir") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
