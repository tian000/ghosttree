import Foundation

public enum OverlayLayer: String, Codable, Sendable {
    case lower
    case upper
}

public struct OverlayEntry: Equatable, Sendable {
    public let path: RelativePath
    public let layer: OverlayLayer
    public let url: URL
}

public struct OverlayChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case added
        case modified
        case deleted
    }

    public let path: String
    public let kind: Kind
}

/// Implements Ghosttree's namespace policy independently from FSKit.
///
/// `upper` mirrors changed paths, while `whiteouts` stores zero-byte markers for
/// lower-layer paths hidden by a session. The FSKit adapter uses these operations
/// to decide which real file descriptor should serve a request.
public final class OverlayStore: @unchecked Sendable {
    public let lowerRoot: URL
    public let stateRoot: URL
    public let upperRoot: URL
    public let whiteoutRoot: URL

    private let fileManager: FileManager
    private let lock = NSRecursiveLock()

    public init(lowerRoot: URL, stateRoot: URL, fileManager: FileManager = .default) throws {
        let resolvedLower = lowerRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedState = stateRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.lowerRoot = resolvedLower
        self.stateRoot = resolvedState
        self.upperRoot = resolvedState.appendingPathComponent("upper", isDirectory: true)
        self.whiteoutRoot = resolvedState.appendingPathComponent("whiteouts", isDirectory: true)
        self.fileManager = fileManager

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: self.lowerRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GhosttreeError.notDirectory(self.lowerRoot.path)
        }
        try fileManager.createDirectory(at: upperRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: whiteoutRoot, withIntermediateDirectories: true)
    }

    public func entry(at path: RelativePath) -> OverlayEntry? {
        lock.withLock {
            let upper = path.url(relativeTo: upperRoot)
            if fileManager.fileExists(atPath: upper.path) {
                return OverlayEntry(path: path, layer: .upper, url: upper)
            }
            guard !isWhiteoutedUnlocked(path) else { return nil }
            let lower = path.url(relativeTo: lowerRoot)
            guard fileManager.fileExists(atPath: lower.path) else { return nil }
            return OverlayEntry(path: path, layer: .lower, url: lower)
        }
    }

    public func mutableURL(for path: RelativePath, recursively: Bool = false) throws -> URL {
        try copyUp(path, recursively: recursively)
    }

    public func read(_ path: RelativePath) throws -> Data {
        guard let entry = entry(at: path) else { throw GhosttreeError.missingItem(path.description) }
        return try Data(contentsOf: entry.url)
    }

    public func contentsOfDirectory(at path: RelativePath = .root) throws -> [String] {
        try lock.withLock {
            guard let visible = entry(at: path) else { throw GhosttreeError.missingItem(path.description) }
            let values = try visible.url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw GhosttreeError.notDirectory(path.description) }

            var names = Set<String>()
            let lower = path.url(relativeTo: lowerRoot)
            if !isWhiteoutedUnlocked(path), fileManager.fileExists(atPath: lower.path) {
                names.formUnion(try fileManager.contentsOfDirectory(atPath: lower.path))
            }
            let upper = path.url(relativeTo: upperRoot)
            if fileManager.fileExists(atPath: upper.path) {
                names.formUnion(try fileManager.contentsOfDirectory(atPath: upper.path))
            }

            return try names.filter { name in
                let child = try path.appending(name)
                return !isWhiteoutedUnlocked(child)
            }.sorted()
        }
    }

    @discardableResult
    public func copyUp(_ path: RelativePath, recursively: Bool = false) throws -> URL {
        try lock.withLock {
            let destination = path.url(relativeTo: upperRoot)
            if fileManager.fileExists(atPath: destination.path) { return destination }
            guard !isWhiteoutedUnlocked(path) else { throw GhosttreeError.missingItem(path.description) }

            let source = path.url(relativeTo: lowerRoot)
            guard fileManager.fileExists(atPath: source.path) else { throw GhosttreeError.missingItem(path.description) }
            try ensureUpperParentUnlocked(for: path)

            let values = try source.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true && !recursively {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            } else {
                try fileManager.copyItem(at: source, to: destination)
            }
            clearWhiteoutUnlocked(path)
            return destination
        }
    }

    public func write(_ data: Data, to path: RelativePath) throws {
        try lock.withLock {
            guard !path.isRoot else { throw GhosttreeError.invalidRelativePath(path.description) }
            try ensureUpperParentUnlocked(for: path)
            let upper = path.url(relativeTo: upperRoot)
            if !fileManager.fileExists(atPath: upper.path) {
                let lower = path.url(relativeTo: lowerRoot)
                if fileManager.fileExists(atPath: lower.path), !isWhiteoutedUnlocked(path) {
                    try fileManager.copyItem(at: lower, to: upper)
                }
            }
            clearWhiteoutsThroughUnlocked(path)
            try data.write(to: upper, options: .atomic)
        }
    }

    public func createDirectory(at path: RelativePath) throws {
        try lock.withLock {
            guard !path.isRoot else { return }
            guard entry(at: path) == nil else { throw POSIXError(.EEXIST) }
            clearWhiteoutsThroughUnlocked(path)
            try fileManager.createDirectory(
                at: path.url(relativeTo: upperRoot),
                withIntermediateDirectories: true
            )
        }
    }

    public func createFile(at path: RelativePath) throws -> URL {
        try lock.withLock {
            guard !path.isRoot else { throw GhosttreeError.invalidRelativePath(path.description) }
            guard entry(at: path) == nil else { throw POSIXError(.EEXIST) }
            try ensureUpperParentUnlocked(for: path)
            clearWhiteoutsThroughUnlocked(path)
            let destination = path.url(relativeTo: upperRoot)
            guard fileManager.createFile(atPath: destination.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return destination
        }
    }

    public func createSymbolicLink(at path: RelativePath, destination: String) throws -> URL {
        try lock.withLock {
            guard !path.isRoot else { throw GhosttreeError.invalidRelativePath(path.description) }
            guard entry(at: path) == nil else { throw POSIXError(.EEXIST) }
            try ensureUpperParentUnlocked(for: path)
            clearWhiteoutsThroughUnlocked(path)
            let url = path.url(relativeTo: upperRoot)
            try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
            return url
        }
    }

    public func move(_ source: RelativePath, to destination: RelativePath) throws {
        try lock.withLock {
            guard !source.isRoot, !destination.isRoot else {
                throw GhosttreeError.invalidRelativePath(source.isRoot ? source.description : destination.description)
            }
            guard entry(at: source) != nil else { throw GhosttreeError.missingItem(source.description) }
            guard destination != source else { return }
            guard !destination.components.starts(with: source.components) else { throw POSIXError(.EINVAL) }

            if let destinationEntry = entry(at: destination) {
                let sourceIsDirectory = try entry(at: source)!.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                let destinationIsDirectory = try destinationEntry.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                if sourceIsDirectory && !destinationIsDirectory { throw POSIXError(.ENOTDIR) }
                if !sourceIsDirectory && destinationIsDirectory { throw POSIXError(.EISDIR) }
                if destinationIsDirectory {
                    let destinationContents = try contentsOfDirectory(at: destination)
                    if !destinationContents.isEmpty { throw POSIXError(.ENOTEMPTY) }
                }
            }

            let sourceLower = source.url(relativeTo: lowerRoot)
            let sourceHadLower = fileManager.fileExists(atPath: sourceLower.path) && !isWhiteoutedUnlocked(source)
            try materializeUnlocked(source)

            let destinationUpper = destination.url(relativeTo: upperRoot)
            try ensureUpperParentUnlocked(for: destination)
            if fileManager.fileExists(atPath: destinationUpper.path) {
                try fileManager.removeItem(at: destinationUpper)
            }
            clearWhiteoutsThroughUnlocked(destination)
            try fileManager.moveItem(at: source.url(relativeTo: upperRoot), to: destinationUpper)

            if sourceHadLower {
                try createWhiteoutUnlocked(source)
            }
        }
    }

    public func remove(_ path: RelativePath) throws {
        try lock.withLock {
            guard !path.isRoot else { throw GhosttreeError.invalidRelativePath(path.description) }
            let upper = path.url(relativeTo: upperRoot)
            let lower = path.url(relativeTo: lowerRoot)
            let hadUpper = fileManager.fileExists(atPath: upper.path)
            let hadLower = fileManager.fileExists(atPath: lower.path) && !isWhiteoutedUnlocked(path)
            guard hadUpper || hadLower else { throw GhosttreeError.missingItem(path.description) }

            if let visible = entry(at: path),
               try visible.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
               !((try? contentsOfDirectory(at: path)) ?? []).isEmpty {
                throw POSIXError(.ENOTEMPTY)
            }

            if hadUpper { try fileManager.removeItem(at: upper) }
            if hadLower { try createWhiteoutUnlocked(path) }
        }
    }

    public func changes() throws -> [OverlayChange] {
        try lock.withLock {
            var changes: [OverlayChange] = []
            for path in try recursivePathsUnlocked(beneath: upperRoot, includeDirectories: true) {
                let existsBelow = fileManager.fileExists(atPath: path.url(relativeTo: lowerRoot).path)
                changes.append(.init(path: path.description, kind: existsBelow ? .modified : .added))
            }
            for path in try recursivePathsUnlocked(beneath: whiteoutRoot, includeDirectories: false) {
                changes.append(.init(path: path.description, kind: .deleted))
            }
            return changes.sorted {
                ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue)
            }
        }
    }

    private func ensureUpperParentUnlocked(for path: RelativePath) throws {
        guard let parent = path.parent, !parent.isRoot else { return }
        let parentURL = parent.url(relativeTo: upperRoot)
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }
    }

    private func materializeUnlocked(_ path: RelativePath) throws {
        guard let visible = entry(at: path) else { throw GhosttreeError.missingItem(path.description) }
        let isDirectory = try visible.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if !isDirectory {
            _ = try copyUp(path)
            return
        }

        let upper = path.url(relativeTo: upperRoot)
        if !fileManager.fileExists(atPath: upper.path) {
            try ensureUpperParentUnlocked(for: path)
            try fileManager.createDirectory(at: upper, withIntermediateDirectories: false)
        }
        for name in try contentsOfDirectory(at: path) {
            try materializeUnlocked(path.appending(name))
        }
    }

    private func whiteoutURL(_ path: RelativePath) -> URL {
        path.url(relativeTo: whiteoutRoot)
    }

    private func isWhiteoutedUnlocked(_ path: RelativePath) -> Bool {
        path.prefixes.contains {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: whiteoutURL($0).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    private func clearWhiteoutUnlocked(_ path: RelativePath) {
        let url = whiteoutURL(path)
        try? fileManager.removeItem(at: url)
    }

    private func clearWhiteoutsThroughUnlocked(_ path: RelativePath) {
        for prefix in path.prefixes { clearWhiteoutUnlocked(prefix) }
    }

    private func createWhiteoutUnlocked(_ path: RelativePath) throws {
        let marker = whiteoutURL(path)
        try fileManager.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: marker.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func recursivePathsUnlocked(beneath root: URL, includeDirectories: Bool) throws -> [RelativePath] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [RelativePath] = []
        for case let url as URL in enumerator {
            let resolvedURL = url.resolvingSymlinksInPath()
            let rootComponents = root.resolvingSymlinksInPath().pathComponents
            let itemComponents = resolvedURL.pathComponents
            guard itemComponents.starts(with: rootComponents) else { continue }
            if !includeDirectories,
               (try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                continue
            }
            let relativeComponents = Array(itemComponents.dropFirst(rootComponents.count))
            guard !relativeComponents.isEmpty else { continue }
            result.append(try RelativePath(components: relativeComponents))
        }
        return result
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
