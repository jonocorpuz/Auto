import Foundation
import Testing
@testable import Auto

struct QuickLookPreviewerTests {
    private let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/clip\($0).mov") }

    @Test func clampsIndexIntoRange() {
        var items = QuickLookItems()
        let a = items.set(urls, at: 99)
        #expect(a)
        #expect(items.index == 2)
        let b = items.set(urls, at: -4)
        #expect(b)
        #expect(items.index == 0)
    }

    @Test func emptyListIsIgnored() {
        var items = QuickLookItems()
        items.set(urls, at: 1)
        let accepted = items.set([], at: 0)
        #expect(!accepted)
        #expect(items.count == 3)
        #expect(items.index == 1)
    }

    @Test func urlLookupIsBoundsSafe() {
        var items = QuickLookItems()
        #expect(items.url(at: 0) == nil)
        items.set(urls, at: 0)
        #expect(items.url(at: 2) == urls[2])
        #expect(items.url(at: 3) == nil)
        #expect(items.url(at: -1) == nil)
    }

    @Test func declinesControlWithoutItems() {
        #expect(QuickLookPreviewer().acceptsControl() == false)
    }
}
