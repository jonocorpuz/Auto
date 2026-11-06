import CoreGraphics
import Foundation
import Testing
@testable import Auto

struct PhotoGrouperTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func photo(_ id: String, camera: String = "A", at t: Double? = 0, hash: UInt64 = 0,
                      faces: [FaceInfo] = [], sharpness: Double = 100, faceSharpness: Double? = nil) -> PhotoRecord {
        PhotoRecord(
            id: id, camera: camera, members: [id], representative: id, stamps: [:],
            metrics: PhotoMetrics(
                captureTime: t.map { t0.addingTimeInterval($0) }, meanLuma: 0.5, lumaStdDev: 0.2,
                clipHighPct: 0, clipLowPct: 0, sharpness: sharpness, faceSharpness: faceSharpness,
                dHash: hash, horizonTiltDeg: nil, faces: faces))
    }

    @Test func hammingCountsBits() {
        #expect(PhotoGrouper.hamming(0, 0) == 0)
        #expect(PhotoGrouper.hamming(0b1011, 0b0001) == 2)
        #expect(PhotoGrouper.hamming(0, .max) == 64)
    }

    @Test func timeGapSplitsBursts() {
        let ps = [Self.photo("a", at: 0), Self.photo("b", at: 1), Self.photo("c", at: 10), Self.photo("d", at: 11)]
        let g = PhotoGrouper.group(ps)
        #expect(g.map { $0.photos.map(\.id) } == [["a", "b"], ["c", "d"]])
        #expect(g.allSatisfy { $0.kind == .burst })
        #expect(g.map(\.id) == [0, 1])
    }

    @Test func hashSplitsInsideGap() {
        let far: UInt64 = 0xFFFF_FFFF_FFFF
        let ps = [Self.photo("a", at: 0), Self.photo("b", at: 0.5), Self.photo("c", at: 1, hash: far), Self.photo("d", at: 1.5, hash: far)]
        let g = PhotoGrouper.group(ps)
        #expect(g.map { $0.photos.map(\.id) } == [["a", "b"], ["c", "d"]])
    }

    @Test func camerasNeverMerge() {
        let ps = [Self.photo("a", camera: "B", at: 0), Self.photo("b", camera: "A", at: 0.1),
                  Self.photo("c", camera: "B", at: 0.2), Self.photo("d", camera: "A", at: 0.3)]
        let g = PhotoGrouper.group(ps)
        #expect(g.map(\.camera) == ["A", "B"])
        #expect(g.map { $0.photos.map(\.id) } == [["b", "d"], ["a", "c"]])
    }

    @Test(arguments: [(25, 3), (12, 1), (13, 2), (24, 2), (30, 3)])
    func oversizedBurstsSplitBalanced(count: Int, chunks: Int) {
        let ps = (0..<count).map { Self.photo(String(format: "p%03d", $0), at: Double($0) * 0.1) }
        let g = PhotoGrouper.group(ps)
        #expect(g.count == chunks)
        #expect(g.allSatisfy { $0.photos.count <= 12 && $0.kind == .burst })
        #expect(g.flatMap(\.photos).map(\.id) == ps.map(\.id))
        let sizes = g.map(\.photos.count)
        #expect(sizes.max()! - sizes.min()! <= 1)
    }

    @Test func singletonsBatchInTimeOrder() {
        let ps = (0..<19).map { Self.photo(String(format: "s%02d", $0), at: Double($0) * 10) }
        let g = PhotoGrouper.group(ps.reversed())
        #expect(g.map(\.photos.count) == [8, 8, 3])
        #expect(g.allSatisfy { $0.kind == .mixed })
        #expect(g.flatMap(\.photos).map(\.id) == ps.map(\.id))
    }

    @Test func idsFollowFirstFrameOrderWithinCamera() {
        let ps = [Self.photo("s1", at: 0), Self.photo("b1", at: 100), Self.photo("b2", at: 100.5), Self.photo("s2", at: 200)]
        let g = PhotoGrouper.group(ps)
        #expect(g.map(\.kind) == [.mixed, .burst])
        #expect(g[0].photos.map(\.id) == ["s1", "s2"])
        #expect(g.map(\.id) == [0, 1])
    }

    @Test func nilTimesAndMetricsDoNotCrash() {
        var noMetrics = Self.photo("z")
        noMetrics.metrics = nil
        let ps = [Self.photo("b", at: nil), Self.photo("a", at: nil), Self.photo("t", at: 0), noMetrics]
        let g = PhotoGrouper.group(ps)
        #expect(g.flatMap(\.photos).count == 4)
        #expect(g.flatMap(\.photos).map(\.id).first == "t")
    }

    @Test func emptyInput() {
        #expect(PhotoGrouper.group([]).isEmpty)
    }

    @Test func eyesClosedRanksBelowOpenEvenIfSharper() {
        let closed = FaceInfo(box: .zero, eyesClosed: true, edgeCut: false, quality: 0.9)
        let open = FaceInfo(box: .zero, eyesClosed: false, edgeCut: false, quality: 0.1)
        let sharpClosed = Self.photo("c", faces: [closed], sharpness: 1000, faceSharpness: 1000)
        let softOpen = Self.photo("o", faces: [open], sharpness: 20, faceSharpness: 20)
        #expect(PhotoRank.score(softOpen) > PhotoRank.score(sharpClosed))
    }

    @Test func rankOrdersBySharpnessThenClip() {
        let sharp = Self.photo("s", sharpness: 500)
        let soft = Self.photo("f", sharpness: 50)
        #expect(PhotoRank.score(sharp) > PhotoRank.score(soft))
        var clipped = sharp
        clipped.metrics?.clipHighPct = 0.5
        #expect(PhotoRank.score(sharp) > PhotoRank.score(clipped))
        var none = sharp
        none.metrics = nil
        #expect(PhotoRank.score(none) == 0)
    }
}
