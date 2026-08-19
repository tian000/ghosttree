import Foundation

public struct GhosttreeSession: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case prepared
        case mounted
    }

    public let id: String
    public let name: String
    public let lowerPath: String
    public let statePath: String
    public let mountPath: String
    public let createdAt: Date
    public var status: Status
}

public final class SessionManager: @unchecked Sendable {
    public let sessionsRoot: URL
    private let fileManager: FileManager

    public init(sessionsRoot: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let sessionsRoot {
            self.sessionsRoot = sessionsRoot.standardizedFileURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.sessionsRoot = applicationSupport
                .appendingPathComponent("Ghosttree", isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
        }
        try fileManager.createDirectory(at: self.sessionsRoot, withIntermediateDirectories: true)
    }

    public func create(lower: URL, name requestedName: String? = nil) throws -> GhosttreeSession {
        let name = requestedName ?? "ghost-\(UUID().uuidString.lowercased().prefix(8))"
        try validate(name)
        let state = sessionsRoot.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: state.path) else {
            throw GhosttreeError.sessionAlreadyExists(name)
        }

        try fileManager.createDirectory(at: state, withIntermediateDirectories: false)
        do {
            _ = try OverlayStore(lowerRoot: lower, stateRoot: state)
            let session = GhosttreeSession(
                id: name,
                name: name,
                lowerPath: lower.standardizedFileURL.path,
                statePath: state.path,
                mountPath: "/Volumes/ghosttree-\(name)",
                createdAt: Date().roundedToMilliseconds,
                status: .prepared
            )
            try persist(session)
            return session
        } catch {
            try? fileManager.removeItem(at: state)
            throw error
        }
    }

    public func list() throws -> [GhosttreeSession] {
        let children = try fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return children.compactMap { try? loadManifest(at: $0) }.sorted { $0.createdAt < $1.createdAt }
    }

    public func session(id: String) throws -> GhosttreeSession {
        try validate(id)
        let directory = sessionsRoot.appendingPathComponent(id, isDirectory: true)
        guard let session = try? loadManifest(at: directory) else {
            throw GhosttreeError.sessionNotFound(id)
        }
        return session
    }

    public func overlay(id: String) throws -> OverlayStore {
        let session = try session(id: id)
        return try OverlayStore(
            lowerRoot: URL(fileURLWithPath: session.lowerPath, isDirectory: true),
            stateRoot: URL(fileURLWithPath: session.statePath, isDirectory: true)
        )
    }

    public func destroy(id: String) throws {
        let session = try session(id: id)
        try fileManager.removeItem(at: URL(fileURLWithPath: session.statePath, isDirectory: true))
    }

    private func persist(_ session: GhosttreeSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        try data.write(
            to: URL(fileURLWithPath: session.statePath).appendingPathComponent("session.json"),
            options: .atomic
        )
    }

    private func loadManifest(at directory: URL) throws -> GhosttreeSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(
            GhosttreeSession.self,
            from: Data(contentsOf: directory.appendingPathComponent("session.json"))
        )
    }

    private func validate(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw GhosttreeError.invalidSessionName(name)
        }
    }
}

private extension Date {
    var roundedToMilliseconds: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1_000).rounded(.down) / 1_000)
    }
}
