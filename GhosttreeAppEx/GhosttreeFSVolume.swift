/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class defines a custom volume for use by the ghosttree file system.
*/

import Foundation
import ExtensionFoundation
import FSKit
import OSLog

let maxSymlinkSize: Int = 4096
let modeAllBits: Int32 = 0o7777

/// A GhosttreeFSVolume represents a volume in the ghosttree file system.
class GhosttreeFSVolume: FSVolume,
                           FSVolume.ReadWriteOperations,
                           FSVolume.RenameOperations,
                           FSVolume.PreallocateOperations,
                           FSVolume.OpenCloseOperations {

    /// The default UUID for the GhosttreeFSVolume.
    static let defaultVolumeUUID = UUID()

    let session: GhosttreeSession
    let overlay: OverlayStore
    private let lowerAccessURL: URL
    private var lowerAccessIsActive: Bool

    /// The root item of the volume.
    var rootItem: GhosttreeFSItem

    /// The item cache stores items previously looked up or created;
    /// items are removed from the dictionary when the volume reclaims or removes the item.
    var itemCache: [UInt64: GhosttreeFSItem]

    /// The item cache is accessed concurrently so the volume needs to serialize access to it.
    var itemCacheQueue: DispatchQueue

    /// Creates a new GhosttreeFSVolume.
    /// - Parameter statePath: The path to a prepared Ghosttree session.
    init(statePath: String) throws {
        let stateURL = URL(fileURLWithPath: statePath, isDirectory: true)
        self.session = try GhosttreeSession.load(from: stateURL)
        if let bookmark = session.lowerBookmark {
            var isStale = false
            self.lowerAccessURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } else {
            self.lowerAccessURL = URL(fileURLWithPath: session.lowerPath, isDirectory: true)
        }
        let lowerAccessIsActive = lowerAccessURL.startAccessingSecurityScopedResource()
        self.lowerAccessIsActive = lowerAccessIsActive
        do {
            self.overlay = try OverlayStore(lowerRoot: lowerAccessURL, stateRoot: stateURL)
        } catch {
            if lowerAccessIsActive { lowerAccessURL.stopAccessingSecurityScopedResource() }
            throw error
        }
        self.rootItem = try GhosttreeFSItem(
            path: .root,
            backingURL: overlay.upperRoot,
            type: .directory,
            openMode: .readOnly
        )
        self.itemCache = [:]
        self.itemCacheQueue = DispatchQueue(label: "dev.ghosttree.fs.itemcache.queue")
        super.init(volumeID: FSVolume.Identifier(uuid: GhosttreeFSVolume.defaultVolumeUUID), volumeName: FSFileName(string: session.name))
        Logger.ghosttreefs.info("\(#function): Created overlay volume for session \(self.session.id)")
    }

    func releaseLowerAccess() {
        guard lowerAccessIsActive else { return }
        lowerAccessURL.stopAccessingSecurityScopedResource()
        lowerAccessIsActive = false
    }

    func prepareForMutation(_ item: GhosttreeFSItem, recursively: Bool = false) throws {
        guard !item.relativePath.isRoot else { return }
        let upperURL = try overlay.mutableURL(for: item.relativePath, recursively: recursively)
        if item.backingURL != upperURL {
            try item.rebind(to: upperURL)
        }
    }

    func item(at path: RelativePath, parent: GhosttreeFSItem?) throws -> GhosttreeFSItem {
        guard let entry = overlay.entry(at: path) else { throw POSIXError(.ENOENT) }
        var statResult = stat()
        guard lstat(entry.url.path, &statResult) == 0 else { throw posixErrno }
        let type: FSItem.ItemType
        switch statResult.st_mode & S_IFMT {
        case S_IFDIR: type = .directory
        case S_IFLNK: type = .symlink
        default: type = .file
        }
        return try GhosttreeFSItem(path: path, backingURL: entry.url, type: type, parent: parent)
    }

    func relocateCachedItems(
        from source: RelativePath,
        to destination: RelativePath,
        movedItem: GhosttreeFSItem,
        destinationParent: GhosttreeFSItem
    ) throws {
        var cached = itemCacheQueue.sync { Array(itemCache.values) }
        if !cached.contains(where: { $0 === movedItem }) { cached.append(movedItem) }

        let affected = cached
            .filter { $0.relativePath.components.starts(with: source.components) }
            .sorted { $0.relativePath.components.count < $1.relativePath.components.count }
        var relocatedByPath: [RelativePath: GhosttreeFSItem] = [:]

        for item in affected {
            let suffix = item.relativePath.components.dropFirst(source.components.count)
            let newPath = try RelativePath(components: destination.components + suffix)
            guard let entry = overlay.entry(at: newPath) else { throw POSIXError(.ENOENT) }
            let newParent: GhosttreeFSItem?
            if newPath == destination {
                newParent = destinationParent
            } else if let parentPath = newPath.parent {
                newParent = relocatedByPath[parentPath] ?? item.parent
            } else {
                newParent = nil
            }
            try item.relocate(to: newPath, backingURL: entry.url, parent: newParent)
            relocatedByPath[newPath] = item
        }

        itemCacheQueue.sync {
            itemCache = Dictionary(uniqueKeysWithValues: cached.map { ($0.inode, $0) })
        }
    }

    /// The GhosttreeFS file system doesn't support setting a volume name, so this method does nothing and invokes its reply handler.
    public func setVolumeName(_ name: FSFileName, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        return replyHandler(name, nil)
    }

    /// Prealocates disk space for the given item using `fcntl`.
    /// - Parameters:
    ///   - item: The item to preallocate space for.
    ///   - offset: The file offset at which to preallocate space.
    ///   - length: The length of the preallocated space.
    ///   - flags: The preallocation flags.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func preallocateSpace(for item: FSItem,
                                 at offset: off_t,
                                 length: Int,
                                 flags: FSVolume.PreallocateFlags,
                                 replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }
        guard ptItem.itemType == .file else {
            Logger.ghosttreefs.error("\(#function): Can only preallocate a file")
            return replyHandler(0, POSIXError(.EPERM))
        }

        do {
            try prepareForMutation(ptItem)
        } catch {
            return replyHandler(0, error)
        }

        var preallocStruct = fstore_t()
        preallocStruct.fst_bytesalloc = 0
        preallocStruct.fst_flags = UInt32(flags.rawValue)
        preallocStruct.fst_length = Int64(length)
        preallocStruct.fst_offset = Int64(offset)
        preallocStruct.fst_posmode = F_PEOFPOSMODE

        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            try? ptItem.upgradeOpenMode(mode: .readWrite)
        }
        var err: Error?
        if fcntl(ptItem.fileDescriptor, F_PREALLOCATE, &preallocStruct) == -1 {
            err = posixErrno
        }
        if oldFD < 0 {
            try? ptItem.closeItem()
        }
        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(Int(preallocStruct.fst_bytesalloc), nil)
    }

    /// Reads the contents of the given file item using `pread`.
    /// - Parameters:
    ///   - item: The file item to read from.
    ///   - offset: The file offset at which to begin reading.
    ///   - length: The number of bytes to read.
    ///   - buffer: The buffer into which to read the data.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func read(from item: FSItem,
                     at offset: off_t,
                     length: Int,
                     into buffer: FSMutableFileDataBuffer,
                     replyHandler: @escaping (Int, Error?) -> Void) {
        guard let ptItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }
        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            try? ptItem.upgradeOpenMode(mode: .readOnly)
        }
        var err: Error?
        var actuallyRead = 0
        buffer.withUnsafeMutableBytes { rawBufferPointer in
            actuallyRead = pread(ptItem.fileDescriptor, rawBufferPointer.baseAddress, length, offset)

            // Check if the read operation was successful.
            if actuallyRead == -1 {
                err = posixErrno
            }
        }

        if oldFD < 0 {
            try? ptItem.closeItem()
        }
        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(actuallyRead, nil)

    }

    /// Writes contents to the given file item using `pwrite`.
    /// - Parameters:
    ///   - contents: The data to write to the file item.
    ///   - item: The file item to write to.
    ///   - offset: The file offset at which to begin writing.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func write(contents: Data,
                      to item: FSItem,
                      at offset: off_t,
                      replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }

        guard ptItem.itemType != .directory else {
            Logger.ghosttreefs.error("\(#function): Can't write to a folder")
            return replyHandler(0, POSIXError(.EISDIR))
        }

        do {
            try prepareForMutation(ptItem)
            try ptItem.upgradeOpenMode(mode: .readWrite)
        } catch {
            return replyHandler(0, error)
        }

        let bytesPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: contents.count)
        contents.copyBytes(to: bytesPtr, count: contents.count)

        var err: Error?
        let actuallyWritten = pwrite(ptItem.fileDescriptor, bytesPtr, contents.count, off_t(offset))
        bytesPtr.deallocate()
        if actuallyWritten == -1 {
            err = posixErrno
        }
        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(actuallyWritten, nil)
    }

    /// Performs an `open` operation on the given file item.
    /// - Parameters:
    ///   - item: The file item to open.
    ///   - modes: The open modes.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func openItem(_ item: FSItem,
                         modes: FSVolume.OpenModes,
                         replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            // root item is opened when creating the volume.
            return replyHandler(nil)
        }

        var ptfsMode: GhosttreeFSItemOpenMode = .close
        if modes.contains(.read) {
            ptfsMode = .readOnly
        }
        if modes.contains(.write) {
            ptfsMode = .readWrite
        }

        do {
            if modes.contains(.write) {
                try prepareForMutation(ptItem)
            }
            try ptItem.upgradeOpenMode(mode: ptfsMode)
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Performs a `close` operation on the given file item.
    /// - Parameters:
    ///   - item: The file item to close.
    ///   - modes: The open modes (ignored for GhosttreeFS).
    ///   - replyHandler: The reply handler to invoke with the result.
    public func closeItem(_ item: FSItem,
                          modes: FSVolume.OpenModes,
                          replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            // Root item is closed in deactivate volume.
            return replyHandler(nil)
        }

        do {
            try ptItem.closeItem()
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Get maximum link count using `fpathconf`.
    public var maximumLinkCount: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_LINK_MAX))
    }

    /// Get maximum name length using `fpathconf`.
    public var maximumNameLength: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_NAME_MAX))
    }

    /// Get whether the volume restricts ownership changes based on authorization using `fpathconf`.
    public var restrictsOwnershipChanges: Bool {
        return fpathconf(self.rootItem.fileDescriptor, _PC_CHOWN_RESTRICTED) == 1
    }

    /// Get whether the volume truncates files longer than its maximum supported length using `fpathconf`.
    public var truncatesLongNames: Bool {
        return fpathconf(self.rootItem.fileDescriptor, _PC_NO_TRUNC) == 0
    }

    /// Get the maximum file size in bits using `fpathconf`.
    public var maximumFileSizeInBits: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_FILESIZEBITS))
    }

    /// Get the maximum extended attribute size in bits using `fpathconf`.
    public var maximumXattrSizeInBits: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_XATTR_SIZE_BITS))
    }
}
