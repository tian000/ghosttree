import Foundation
import GhosttreeCore

@main
struct GhosttreeCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("ghosttree: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        let args = Array(arguments.dropFirst())

        switch command {
        case "create":
            let manager = try sessionManager(from: args)
            guard let lower = value(after: "--lower", in: args) else {
                throw CLIError("create requires --lower <directory>")
            }
            let session = try manager.create(
                lower: URL(fileURLWithPath: NSString(string: lower).expandingTildeInPath, isDirectory: true),
                name: value(after: "--name", in: args)
            )
            let result = try args.contains("--mount") ? mount(session, with: manager) : session
            if args.contains("--json") { try printJSON(SessionOutput(result)) }
            else {
                print(result.status == .mounted ? "Mounted \(result.name)" : "Prepared \(result.name)")
                print("State: \(result.statePath)")
                print("Mount: \(result.mountPath)")
            }

        case "mount":
            let manager = try sessionManager(from: args)
            guard let id = positional(in: args) else { throw CLIError("mount requires <id>") }
            let session = try mount(manager.session(id: id), with: manager)
            print(session.mountPath)

        case "unmount":
            let manager = try sessionManager(from: args)
            guard let id = positional(in: args) else { throw CLIError("unmount requires <id>") }
            try unmount(manager.session(id: id), with: manager)
            print("Unmounted \(id)")

        case "list":
            let manager = try sessionManager(from: args)
            let sessions = try manager.list()
            if args.contains("--json") { try printJSON(sessions.map(SessionOutput.init)) }
            else if sessions.isEmpty { print("No ghosttrees") }
            else {
                for session in sessions {
                    print("\(session.id)\t\(session.status.rawValue)\t\(session.lowerPath)")
                }
            }

        case "inspect":
            let manager = try sessionManager(from: args)
            guard let id = positional(in: args) else { throw CLIError("inspect requires <id>") }
            try printJSON(SessionOutput(manager.session(id: id)))

        case "diff":
            let manager = try sessionManager(from: args)
            guard let id = positional(in: args) else { throw CLIError("diff requires <id>") }
            let changes = try manager.overlay(id: id).changes()
            if args.contains("--json") { try printJSON(changes) }
            else if changes.isEmpty { print("No changes") }
            else {
                for change in changes {
                    let marker = switch change.kind {
                    case .added: "A"
                    case .modified: "M"
                    case .deleted: "D"
                    }
                    print("\(marker)\t\(change.path)")
                }
            }

        case "destroy":
            let manager = try sessionManager(from: args)
            guard let id = positional(in: args) else { throw CLIError("destroy requires <id>") }
            guard args.contains("--force") else { throw CLIError("destroy requires --force") }
            guard try manager.session(id: id).status != .mounted else {
                throw CLIError("\(id) is mounted; run ghosttree unmount \(id) first")
            }
            try manager.destroy(id: id)
            print("Destroyed \(id)")

        case "doctor":
            let version = ProcessInfo.processInfo.operatingSystemVersion
            print("macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
            print(version.majorVersion >= 26 ? "Native FSKit path resources: available" : "Native FSKit path resources: unavailable (requires macOS 26)")

        case "help", "--help", "-h":
            printHelp()

        default:
            throw CLIError("unknown command: \(command)")
        }
    }

    private static func sessionManager(from args: [String]) throws -> SessionManager {
        try SessionManager(sessionsRoot: stateRoot(from: args))
    }

    private static func mount(_ session: GhosttreeSession, with manager: SessionManager) throws -> GhosttreeSession {
        guard operatingSystemSupportsNativeMounts else {
            throw CLIError("native mounts require macOS 26 or newer")
        }
        if session.status == .mounted { return session }

        let mountURL = URL(fileURLWithPath: session.mountPath, isDirectory: true)
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        try runProcess("/sbin/mount", arguments: ["-t", "ghosttree", session.statePath, session.mountPath])
        return try manager.setStatus(.mounted, for: session.id)
    }

    private static func unmount(_ session: GhosttreeSession, with manager: SessionManager) throws {
        if session.status == .mounted {
            try runProcess("/sbin/umount", arguments: [session.mountPath])
            _ = try manager.setStatus(.prepared, for: session.id)
        }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: session.mountPath, isDirectory: true))
    }

    private static func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(message.isEmpty ? "\(executable) failed with status \(process.terminationStatus)" : message)
        }
    }

    private static var operatingSystemSupportsNativeMounts: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    private static func stateRoot(from args: [String]) -> URL? {
        if let path = value(after: "--state-root", in: args) {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        }
        if let path = ProcessInfo.processInfo.environment["GHOSTTREE_HOME"] {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        }
        return nil
    }

    private static func positional(in args: [String]) -> String? {
        var skipNext = false
        for argument in args {
            if skipNext { skipNext = false; continue }
            if argument == "--state-root" { skipNext = true; continue }
            if !argument.hasPrefix("-") { return argument }
        }
        return nil
    }

    private static func value(after option: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: option), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private static func printHelp() {
        print("""
        ghosttree — instant copy-on-write directory overlays for macOS

        Usage:
          ghosttree create --lower <directory> [--name <name>] [--mount] [--json]
          ghosttree mount <id>
          ghosttree unmount <id>
          ghosttree list [--json]
          ghosttree inspect <id>
          ghosttree diff <id> [--json]
          ghosttree destroy <id> --force
          ghosttree doctor

        Set GHOSTTREE_HOME or pass --state-root to override session storage.
        """)
    }
}

private struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct SessionOutput: Encodable {
    let id: String
    let name: String
    let lowerPath: String
    let statePath: String
    let mountPath: String
    let createdAt: Date
    let status: GhosttreeSession.Status

    init(_ session: GhosttreeSession) {
        id = session.id
        name = session.name
        lowerPath = session.lowerPath
        statePath = session.statePath
        mountPath = session.mountPath
        createdAt = session.createdAt
        status = session.status
    }
}
