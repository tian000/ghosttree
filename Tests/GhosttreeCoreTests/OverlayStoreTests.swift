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

    @Test func movingLowerDirectoryMaterializesMergedContents() throws {
        let fixture = try Fixture()
        try fixture.writeLower("lower", at: "source/lower.txt")
        try fixture.overlay.write(Data("upper".utf8), to: RelativePath("source/upper.txt"))

        try fixture.overlay.move(RelativePath("source"), to: RelativePath("moved"))

        #expect(fixture.overlay.entry(at: try RelativePath("source")) == nil)
        #expect(String(decoding: try fixture.overlay.read(RelativePath("moved/lower.txt")), as: UTF8.self) == "lower")
        #expect(String(decoding: try fixture.overlay.read(RelativePath("moved/upper.txt")), as: UTF8.self) == "upper")
    }

    @Test func movingOverLowerFileReplacesItWithoutChangingLowerLayer() throws {
        let fixture = try Fixture()
        try fixture.writeLower("source", at: "source.txt")
        try fixture.writeLower("destination", at: "destination.txt")

        try fixture.overlay.move(RelativePath("source.txt"), to: RelativePath("destination.txt"))

        #expect(String(decoding: try fixture.overlay.read(RelativePath("destination.txt")), as: UTF8.self) == "source")
        #expect(try String(contentsOf: fixture.lower.appendingPathComponent("destination.txt"), encoding: .utf8) == "destination")
        #expect(fixture.overlay.entry(at: try RelativePath("source.txt")) == nil)
    }

    @Test func createsFilesAndSymbolicLinksOnlyInUpperLayer() throws {
        let fixture = try Fixture()

        let file = try fixture.overlay.createFile(at: RelativePath("new.txt"))
        let link = try fixture.overlay.createSymbolicLink(at: RelativePath("new-link"), destination: "new.txt")

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "new.txt")
        #expect(!FileManager.default.fileExists(atPath: fixture.lower.appendingPathComponent("new.txt").path))
    }

    @Test func refusesToRemoveVisibleNonemptyDirectory() throws {
        let fixture = try Fixture()
        try fixture.writeLower("content", at: "dir/file.txt")

        #expect(throws: POSIXError.self) {
            try fixture.overlay.remove(RelativePath("dir"))
        }
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
        #expect(created.lowerBookmark != nil)
        if let bookmark = created.lowerBookmark {
            var isStale = false
            let resolved = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #expect(resolved.standardizedFileURL == lower.standardizedFileURL)
        }
        #expect(try manager.list() == [created])
        #expect(try manager.session(id: created.id) == created)
        #expect(try manager.setStatus(.mounted, for: created.id).status == .mounted)
        #expect(try manager.setStatus(.prepared, for: created.id).status == .prepared)
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
