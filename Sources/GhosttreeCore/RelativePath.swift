import Foundation

public enum GhosttreeError: Error, Equatable, CustomStringConvertible {
    case invalidRelativePath(String)
    case missingItem(String)
    case notDirectory(String)
    case sessionAlreadyExists(String)
    case sessionNotFound(String)
    case invalidSessionName(String)

    public var description: String {
        switch self {
        case .invalidRelativePath(let path): "invalid relative path: \(path)"
        case .missingItem(let path): "item does not exist: \(path)"
        case .notDirectory(let path): "item is not a directory: \(path)"
        case .sessionAlreadyExists(let name): "session already exists: \(name)"
        case .sessionNotFound(let name): "session not found: \(name)"
        case .invalidSessionName(let name): "invalid session name: \(name)"
        }
    }
}

public struct RelativePath: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public let components: [String]

    public init(_ rawValue: String = "") throws {
        guard !rawValue.hasPrefix("/"), !rawValue.utf8.contains(0) else {
            throw GhosttreeError.invalidRelativePath(rawValue)
        }

        let components = rawValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GhosttreeError.invalidRelativePath(rawValue)
        }
        self.components = components
    }

    public init(components: [String]) throws {
        try self.init(components.joined(separator: "/"))
    }

    public static let root = try! RelativePath()

    public var description: String { components.joined(separator: "/") }
    public var isRoot: Bool { components.isEmpty }

    public var parent: RelativePath? {
        guard !components.isEmpty else { return nil }
        return try? RelativePath(components: Array(components.dropLast()))
    }

    public func appending(_ component: String) throws -> RelativePath {
        try RelativePath(components: components + [component])
    }

    public func url(relativeTo root: URL) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
    }

    public var prefixes: [RelativePath] {
        guard !components.isEmpty else { return [] }
        return (1...components.count).compactMap {
            try? RelativePath(components: Array(components.prefix($0)))
        }
    }

    public static func < (lhs: RelativePath, rhs: RelativePath) -> Bool {
        lhs.description < rhs.description
    }
}
