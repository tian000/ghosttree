/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An FSKit item whose identity is an overlay-relative path and whose backing URL
can move from the lower layer to the upper layer after copy-up.
*/

import ExtensionFoundation
import Foundation
import FSKit
import OSLog

enum GhosttreeFSItemOpenMode: Int32 {
    case close = -1
    case readOnly = 0
    case readWrite = 1
}

final class GhosttreeFSItem: FSItem {
    var fileDescriptor: Int32 = -1
    var openMode: GhosttreeFSItemOpenMode = .close
    weak var parent: GhosttreeFSItem?
    var name: String
    var itemType: FSItem.ItemType
    var inode: UInt64
    private(set) var relativePath: RelativePath
    private(set) var backingURL: URL
    private let openModeQueue: DispatchQueue

    init(
        path: RelativePath,
        backingURL: URL,
        type: FSItem.ItemType,
        parent: GhosttreeFSItem? = nil,
        openMode: GhosttreeFSItemOpenMode = .close
    ) throws {
        self.relativePath = path
        self.backingURL = backingURL
        self.name = path.components.last ?? "."
        self.itemType = type
        self.parent = parent
        self.inode = Self.identifier(for: path)
        self.openModeQueue = DispatchQueue(label: "dev.ghosttree.fs.item.\(self.inode).openmode.queue")
        super.init()

        if openMode != .close {
            try upgradeOpenMode(mode: openMode)
        }
    }

    func rebind(to backingURL: URL) throws {
        try openModeQueue.sync {
            if fileDescriptor >= 0 {
                _ = try throwErrno { Darwin.close(fileDescriptor) }
            }
            self.backingURL = backingURL
            fileDescriptor = -1
            openMode = .close
        }
    }

    func relocate(to path: RelativePath, backingURL: URL, parent: GhosttreeFSItem?) throws {
        try rebind(to: backingURL)
        self.relativePath = path
        self.name = path.components.last ?? "."
        self.parent = parent
    }

    func upgradeOpenMode(mode: GhosttreeFSItemOpenMode) throws {
        guard mode != .close else { throw POSIXError(.EINVAL) }
        if fileDescriptor >= 0 && (openMode == .readWrite || openMode == mode) { return }

        try openModeQueue.sync {
            let flags = mode == .readWrite ? O_RDWR : O_RDONLY
            let newDescriptor = try throwErrno { Darwin.open(backingURL.path, flags | O_SYMLINK) }
            if fileDescriptor >= 0 {
                _ = try throwErrno { Darwin.close(fileDescriptor) }
            }
            fileDescriptor = newDescriptor
            openMode = mode
        }
    }

    func closeItem() throws {
        try openModeQueue.sync {
            guard fileDescriptor >= 0 else { return }
            _ = try throwErrno { Darwin.close(fileDescriptor) }
            fileDescriptor = -1
            openMode = .close
        }
    }

    private static func identifier(for path: RelativePath) -> UInt64 {
        if path.isRoot { return 2 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.description.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return max(hash, 3)
    }
}
