import Foundation
import Testing
@testable import Auto

struct ShootBrowserTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShootBrowserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @discardableResult
    private func file(_ rel: String, in root: URL, bytes: Int = 4) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    private func dir(_ rel: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(rel, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: list

    @Test func foldersFirstThenLocalizedSort() throws {
        let root = try temp()
        try file("clip10.mp4", in: root)
        try file("clip2.mp4", in: root)
        try file("Alpha.jpg", in: root)
        try dir("Zeta", in: root)
        try dir("day 2", in: root)

        let names = ShootBrowser.list(root).map(\.name)
        #expect(names == ["day 2", "Zeta", "Alpha.jpg", "clip2.mp4", "clip10.mp4"])
    }

    @Test func hidesDotfilesAndAutoCullFolder() throws {
        let root = try temp()
        try file(".DS_Store", in: root)
        try file("visible.mp4", in: root)
        try dir(".auto-cull", in: root)
        try file(".hidden/inside.mp4", in: root)

        #expect(ShootBrowser.list(root).map(\.name) == ["visible.mp4"])
    }

    @Test func reportsFolderFileSizeAndKind() throws {
        let root = try temp()
        try dir("Video", in: root)
        try file("Video/A.MOV", in: root, bytes: 42)
        try file("notes.txt", in: root, bytes: 7)
        try file("Photo.ARW", in: root, bytes: 9)

        let entries = ShootBrowser.list(root)
        let folder = entries.first { $0.name == "Video" }
        let mov = ShootBrowser.list(root.appendingPathComponent("Video")).first
        let txt = entries.first { $0.name == "notes.txt" }
        let raw = entries.first { $0.name == "Photo.ARW" }

        #expect(folder?.isFolder == true)
        #expect(folder?.kind == nil)
        #expect(mov?.kind == .video)
        #expect(mov?.size == 42)
        #expect(mov?.isFolder == false)
        #expect(txt?.isFolder == false)
        #expect(txt?.kind == nil)
        #expect(txt?.size == 7)
        #expect(raw?.kind == .photo)
        #expect(entries.allSatisfy { $0.date != .distantPast })
    }

    @Test func missingFolderListsEmpty() throws {
        let root = try temp()
        #expect(ShootBrowser.list(root.appendingPathComponent("nope", isDirectory: true)).isEmpty)
    }

    @Test func symlinksHiddenWithoutRoot() throws {
        let root = try temp()
        let outside = try temp()
        try file("real.mp4", in: outside)
        try file("inside.mp4", in: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out.mp4"),
                                                   withDestinationURL: outside.appendingPathComponent("real.mp4"))
        #expect(ShootBrowser.list(root).map(\.name) == ["inside.mp4"])
    }

    @Test func symlinksInsideRootShownOutsideHidden() throws {
        let root = try temp()
        let outside = try temp()
        try file("real.mp4", in: root)
        try file("elsewhere.mp4", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.mp4"),
                                                   withDestinationURL: root.appendingPathComponent("real.mp4"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.mp4"),
                                                   withDestinationURL: outside.appendingPathComponent("elsewhere.mp4"))

        let names = ShootBrowser.list(root, root: root).map(\.name)
        #expect(names == ["alias.mp4", "real.mp4"])
    }

    @Test func symlinkedFolderOutOfTreeIsHidden() throws {
        let root = try temp()
        let outside = try temp()
        try dir("Video", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked"),
                                                   withDestinationURL: outside.appendingPathComponent("Video"))
        #expect(ShootBrowser.list(root, root: root).isEmpty)
    }

    // MARK: breadcrumb

    @Test func breadcrumbWalksFromRootToFolder() throws {
        let root = try temp()
        let deep = root.appendingPathComponent("Video/FX3/Day 2", isDirectory: true)
        let crumbs = try #require(ShootBrowser.breadcrumb(from: root, to: deep))
        #expect(crumbs.map(\.name) == [root.lastPathComponent, "Video", "FX3", "Day 2"])
        #expect(crumbs.last?.url == deep)
        #expect(crumbs[1].url == root.appendingPathComponent("Video", isDirectory: true))
    }

    @Test func breadcrumbOfRootIsRootOnly() throws {
        let root = try temp()
        let crumbs = try #require(ShootBrowser.breadcrumb(from: root, to: root))
        #expect(crumbs.count == 1)
        #expect(crumbs[0].url == root)
    }

    @Test func breadcrumbNilOutsideRoot() {
        let root = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding")
        #expect(ShootBrowser.breadcrumb(from: root, to: URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding2")) == nil)
        #expect(ShootBrowser.breadcrumb(from: root, to: URL(fileURLWithPath: "/Volumes/Work/Shoots")) == nil)
        #expect(ShootBrowser.breadcrumb(from: root, to: URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding/../Other")) == nil)
    }

    // MARK: clamp

    @Test func clampKeepsFoldersInsideRoot() {
        let root = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding")
        let inside = root.appendingPathComponent("Photo/A7", isDirectory: true)
        #expect(ShootBrowser.clamp(inside, root: root) == inside)
        #expect(ShootBrowser.clamp(root, root: root) == root)
    }

    @Test func clampStopsParentEscapes() {
        let root = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding")
        let escape = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding/Video/../../Promo")
        #expect(ShootBrowser.clamp(escape, root: root) == root)
        #expect(ShootBrowser.clamp(URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding2"), root: root) == root)
        #expect(ShootBrowser.clamp(URL(fileURLWithPath: "/Volumes/Work"), root: root) == root)
    }

    @Test func clampNormalisesDotComponentsInside() {
        let root = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding")
        let messy = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding/Video/./FX3/../FX3")
        #expect(ShootBrowser.clamp(messy, root: root).path == "/Volumes/Work/Shoots/Wedding/Video/FX3")
    }

    // MARK: dropTarget

    @Test func dropOnTopLevelVideoOrPhotoIsSorted() {
        let root = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding")
        #expect(ShootBrowser.dropTarget(for: root, root: root) == .sorted)
        #expect(ShootBrowser.dropTarget(for: root.appendingPathComponent("Video"), root: root) == .sorted)
        #expect(ShootBrowser.dropTarget(for: root.appendingPathComponent("Photo"), root: root) == .sorted)
    }

    @Test func dropOnCameraFolderOrDeeperIsExact() {
        let root = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding")
        let fx3 = root.appendingPathComponent("Video/FX3", isDirectory: true)
        let day2 = fx3.appendingPathComponent("Day 2", isDirectory: true)
        let rejects = root.appendingPathComponent("Photo/A7/_Rejects", isDirectory: true)
        #expect(ShootBrowser.dropTarget(for: fx3, root: root) == .exact(fx3))
        #expect(ShootBrowser.dropTarget(for: day2, root: root) == .exact(day2))
        #expect(ShootBrowser.dropTarget(for: rejects, root: root) == .exact(rejects))
    }

    @Test func lowercaseVideoFolderIsNotTheSortedFolder() {
        let root = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding")
        let lower = root.appendingPathComponent("video", isDirectory: true)
        #expect(ShootBrowser.dropTarget(for: lower, root: root) == .exact(lower))
    }

    @Test func dropOutsideRootFallsBackToSorted() {
        let root = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding")
        #expect(ShootBrowser.dropTarget(for: URL(fileURLWithPath: "/Volumes/Work/Shoots/Promo"), root: root) == .sorted)
    }

    @Test func dropTargetNeverEscapesRoot() {
        let root = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding")
        // Lexically this is Promo/Video/FX3, outside the shoot: falls back to the top level, never an exact drop there.
        let escape = URL(fileURLWithPath: "/Volumes/Work/Shoots/Wedding/Video/../../Promo/Video/FX3")
        #expect(ShootBrowser.dropTarget(for: escape, root: root) == .sorted)
    }
}
