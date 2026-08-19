import Foundation
import Testing
@testable import GhosttreeCore

@Suite("OverlayStore")
struct OverlayStoreTests {
    @Test func lowerReadsAndCopyOnWrite() throws {
        let fixture = try Fixture()
        try fixture.writeLower("original", at: "src/file.txt")

        #expect(String(decoding: try fixture.overlay.read(RelativePath("src/file.txt")), as: UTF8.self) == "original")
        try fixture.overlay.write(Data("changed".utf8), to: RelativePath("src/file.txt"))

        #expect(String(decoding: try fixture.overlay.read(RelativePath("src/file.txt")), as: UTF8.self) == "changed")
        #expect(try String(contentsOf: fixture.lower.appendingPathComponent("src/file.txt"), encoding: .utf8) == "original")
        #expect(fixture.overlay.entry(at: try RelativePath("src/file.txt"))?.layer == .upper)
    }

    @Test func deletionWhiteoutsLowerItem() throws {
        let fixture = try Fixture()
        try fixture.writeLower("keep below", at: "gone.txt")

        try fixture.overlay.remove(RelativePath("gone.txt"))

        #expect(fixture.overlay.entry(at: try RelativePath("gone.txt")) == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.lower.appendingPathComponent("gone.txt").path))
        #expect(try fixture.overlay.changes() == [.init(path: "gone.txt", kind: .deleted)])
    }

    @Test func directoryListingsMergeLayersAndHideWhiteouts() throws {
        let fixture = try Fixture()
        try fixture.writeLower("a", at: "dir/a.txt")
        try fixture.writeLower("b", at: "dir/b.txt")
        try fixture.overlay.write(Data("c".utf8), to: RelativePath("dir/c.txt"))
        try fixture.overlay.remove(RelativePath("dir/b.txt"))

        #expect(try fixture.overlay.contentsOfDirectory(at: RelativePath("dir")) == ["a.txt", "c.txt"])
    }

    @Test func recreatingDeletedPathClearsWhiteout() throws {
        let fixture = try Fixture()
        try fixture.writeLower("old", at: "file.txt")
        try fixture.overlay.remove(RelativePath("file.txt"))
        try fixture.overlay.write(Data("new".utf8), to: RelativePath("file.txt"))

        #expect(String(decoding: try fixture.overlay.read(RelativePath("file.txt")), as: UTF8.self) == "new")
        #expect(try fixture.overlay.changes() == [.init(path: "file.txt", kind: .modified)])
    }

    @Test func rejectsTraversal() {
        #expect(throws: GhosttreeError.invalidRelativePath("../secret")) {
            try RelativePath("../secret")
        }
        #expect(throws: GhosttreeError.invalidRelativePath("/absolute")) {
            try RelativePath("/absolute")
        }
    }
}

@Suite("SessionManager")
struct SessionManagerTests {
    @Test func createsListsAndDestroysSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lower = root.appendingPathComponent("lower")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: lower, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = try SessionManager(sessionsRoot: sessions)
        let created = try manager.create(lower: lower, name: "test-tree")

        #expect(created.status == .prepared)
        #expect(try manager.list() == [created])
        #expect(try manager.session(id: created.id) == created)
        try manager.destroy(id: created.id)
        #expect(try manager.list().isEmpty)
    }
}

private struct Fixture {
    let root: URL
    let lower: URL
    let state: URL
    let overlay: OverlayStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        lower = root.appendingPathComponent("lower")
        state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: lower, withIntermediateDirectories: true)
        overlay = try OverlayStore(lowerRoot: lower, stateRoot: state)
    }

    func writeLower(_ string: String, at path: String) throws {
        let url = lower.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
    }
}
