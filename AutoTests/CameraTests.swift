import Foundation
import Testing
@testable import Auto

struct CameraTests {
    private func cam(_ id: String, _ model: String = "FX3") -> Camera {
        Camera(id: id, model: model, serial: nil, folderName: model)
    }

    @Test func suffixSkipsTakenNames() {
        let out = Camera.disambiguated([cam("a", "FX3 A"), cam("b"), cam("c")])
        let labels = out.map { $0.label.lowercased() }
        let folders = out.map { $0.folderName.lowercased() }
        #expect(Set(labels).count == 3)
        #expect(Set(folders).count == 3)
        #expect(out[0].label == "FX3 A")
        #expect(out[1].label == "FX3 B")
        #expect(out[2].label == "FX3 C")
    }

    @Test func suffixStableByID() {
        let cams = [cam("3"), cam("1"), cam("2")]
        let forward = Camera.disambiguated(cams)
        let shuffled = Camera.disambiguated(cams.reversed())
        func map(_ c: [Camera]) -> [String: String] { Dictionary(uniqueKeysWithValues: c.map { ($0.id, $0.label) }) }
        #expect(map(forward) == map(shuffled))
        #expect(map(forward)["1"] == "FX3 A")
        #expect(forward.map(\.id) == ["3", "1", "2"])
    }

    @Test func singleBodyHasNoSuffix() {
        let out = Camera.disambiguated([cam("1"), cam("2", "A7")])
        #expect(out.map(\.label) == ["FX3", "A7"])
        #expect(out.map(\.folderName) == ["FX3", "A7"])
    }

    @Test func defaultFolderNameMatchesSuffix() {
        let out = Camera.disambiguated([cam("1"), cam("2")])
        #expect(out.map(\.defaultFolderName) == ["FX3 A", "FX3 B"])
        var edited = out[0]
        edited.folderName = ""
        #expect(edited.defaultFolderName == "FX3 A")
    }

    @Test func numbersAfterZ() {
        let cams = (0..<28).map { cam(String(format: "%02d", $0)) }
        let out = Camera.disambiguated(cams)
        #expect(Set(out.map { $0.label.lowercased() }).count == 28)
        #expect(out[25].label == "FX3 Z")
        #expect(out[26].label == "FX3 1")
        #expect(out[27].label == "FX3 2")
    }
}
