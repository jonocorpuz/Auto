import Foundation
import Testing
@testable import Auto

struct PhotoCatalogTests {
    private func scan(_ f: FixtureShoot, cards: [URL] = []) throws -> [PhotoRecord] {
        try PhotoCatalog.scan(shoot: f.root, cardVolumes: cards)
    }

    @Test func pairsRawAndJpeg() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        f.add("Photo/A7IV/DSC001.ARW"); f.add("Photo/A7IV/dsc001.JPG")
        let r = try scan(f)
        #expect(r.count == 1)
        #expect(r[0].members.count == 2)
        #expect(r[0].representative == "Photo/A7IV/dsc001.JPG")
        #expect(r[0].id == r[0].representative)
        #expect(r[0].camera == "A7IV")
        #expect(r[0].metrics == nil)
    }

    @Test func loneRawIsRepresentative() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        f.add("Photo/A7IV/DSC002.ARW")
        let r = try scan(f)
        #expect(r.count == 1)
        #expect(r[0].representative == "Photo/A7IV/DSC002.ARW")
    }

    @Test func skipsExcluded() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        f.add("Photo/Cam/ok.jpg")
        f.add("Photo/Cam/_Rejects/r.jpg")
        f.add("Photo/Cam/.hidden.jpg")
        f.add("Photo/.hiddendir/h.jpg")
        f.add("Video/x.jpg")
        f.add("Photo/Cam/notes.txt")
        let outside = f.add("outside/real.jpg")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: f.root.appendingPathComponent("Photo/Cam/link.jpg"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: f.root.appendingPathComponent("Photo/Cam/linkdir"), withDestinationURL: outside.deletingLastPathComponent())
        let r = try scan(f)
        #expect(r.map(\.id) == ["Photo/Cam/ok.jpg"])
    }

    @Test func includesHeicAndInsp() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        f.add("Photo/Phone/a.heic"); f.add("Photo/Insta/b.insp")
        let r = try scan(f)
        #expect(Set(r.map(\.id)) == ["Photo/Phone/a.heic", "Photo/Insta/b.insp"])
        #expect(r.map(\.camera) == ["Insta", "Phone"])
    }

    @Test func nestedCameraName() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        f.add("Photo/Cam/DCIM/100/x.jpg"); f.add("Photo/loose.jpg")
        let r = try scan(f)
        #expect(r.first { $0.id == "Photo/Cam/DCIM/100/x.jpg" }?.camera == "Cam")
        #expect(r.first { $0.id == "Photo/loose.jpg" }?.camera == "")
    }

    @Test func missingPhotoFolder() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        #expect(try scan(f).isEmpty)
    }

    @Test func onCardThrows() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        f.add("Photo/Cam/a.jpg")
        #expect(throws: CullError.onCard) { try scan(f, cards: [f.root.deletingLastPathComponent()]) }
    }

    @Test func stampsMatchSize() throws {
        let f = FixtureShoot(); defer { f.cleanup() }
        f.add("Photo/Cam/a.jpg", bytes: Data(count: 123))
        let r = try scan(f)
        #expect(r[0].stamps["Photo/Cam/a.jpg"]?.size == 123)
    }
}
