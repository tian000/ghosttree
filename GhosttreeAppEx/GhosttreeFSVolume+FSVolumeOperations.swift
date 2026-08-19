/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The implementation of the ghosttree file system's conformance to the operations required of an FSKit volume.
*/

import Foundation
import ExtensionFoundation
import FSKit
import OSLog


/// A structure that holds common attributes for all items.
private struct CommonAttributes {
    var length: UInt32
    var backupTime: timespec
    var parentID: UInt64
    var addedTime: timespec

    init() {
        self.length = 0
        self.backupTime = timespec(tv_sec: 0, tv_nsec: 0)
        self.parentID = 0
        self.addedTime = timespec(tv_sec: 0, tv_nsec: 0)
    }
}

/// Implementing FSVolume.Operations.
extension GhosttreeFSVolume: FSVolume.Operations {

    /// Returns volume statistics using `fstatfs`.
    public var volumeStatistics: FSStatFSResult {
        var statfsResult = statfs()
        let res = FSStatFSResult(fileSystemTypeName: String("ghosttreefs"))
        if fstatfs(self.rootItem.fileDescriptor, &statfsResult) == -1 {
            return res
        }
        // Convert the statfs result to FSStatFSResult
        res.blockSize           = Int(statfsResult.f_bsize)
        res.ioSize              = Int(statfsResult.f_iosize)
        res.totalBlocks         = UInt64(statfsResult.f_blocks)
        res.availableBlocks     = UInt64(statfsResult.f_bavail)
        res.freeBlocks          = UInt64(statfsResult.f_bfree)
        res.usedBlocks          = res.totalBlocks - res.freeBlocks
        res.totalFiles          = UInt64(statfsResult.f_files)
        res.freeFiles           = UInt64(statfsResult.f_ffree)
        res.fileSystemSubType   = Int(statfsResult.f_fssubtype)
        return res
    }

    /// Activates the volume, but GhosttreeFS volume activation doesn't need to do anything, so this method just replies with the root item.
    ///
    /// - Parameters
    ///   - options: The activation options.
    ///   - reply: The reply handler to invoke when the activation is complete.
    public func activate(options: FSTaskOptions,
                         replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        return reply(self.rootItem, nil)
    }

    /// Deactivates the volume, by closing the root item.
    /// - Parameters:
    ///   - options: The deactivation options.
    ///   - replyHandler: The reply handler to invoke when the deactivation is complete.
    public func deactivate(options: FSDeactivateOptions = [],
                           replyHandler: @escaping ((any Error)?) -> Void) {
        try? self.rootItem.closeItem()
        self.releaseLowerAccess()
        return replyHandler(nil)
    }

    /// Mount in GhosttreeFSVolume doesn't need to do anything; implementation just replies with nil error.
    public func mount(options: FSTaskOptions,
                      replyHandler: @escaping (Error?) -> Void) {
        return replyHandler(nil)
    }

    /// Unmount closes the root item.
    public func unmount(replyHandler: @escaping () -> Void) {
        try? self.rootItem.closeItem()
        self.releaseLowerAccess()
        return replyHandler()
    }

    /// Performs synchronize using `fsync` on the root item, ignoring the FSSyncFlags flags, which GhosttreeFS doesn't support.
    /// - Parameters
    ///   - flags: The sync flags.
    ///   - reply: The reply handler to invoke when the sync is complete.
    public func synchronize(flags: FSSyncFlags,
                            replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard fsync(self.rootItem.fileDescriptor) == 0 else {
            let err = posixErrno
            Logger.ghosttreefs.error("\(#function): Failed to synchronize with error(\(err))")
            return reply(err)
        }
        return reply(nil)
    }

    private func getCommonAttributes(ptItem: GhosttreeFSItem,
                                     desiredAttributes: FSItem.GetAttributesRequest) throws -> CommonAttributes {

        var attrgroupFlags: Int32 = 0
        if desiredAttributes.isAttributeWanted(.parentID) {
            attrgroupFlags |= ATTR_CMN_PARENTID
        }
        if desiredAttributes.isAttributeWanted(.addedTime) {
            attrgroupFlags |= ATTR_CMN_ADDEDTIME
        }
        if desiredAttributes.isAttributeWanted(.backupTime) {
            attrgroupFlags |= ATTR_CMN_BKUPTIME
        }
        let commonAttrsWanted = attrgroup_t(attrgroupFlags)
        var attrList = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: commonAttrsWanted,
                                volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var commonAttrsBuf = CommonAttributes()

        if attrgroupFlags != 0 {
            if fgetattrlist(ptItem.fileDescriptor, &attrList, &commonAttrsBuf, MemoryLayout<CommonAttributes>.size, UInt32(FSOPT_NOFOLLOW)) == -1 {
                throw posixErrno
            }
        }
        return commonAttrsBuf
    }

    /// Fetches attributes for the given item.
    /// The method uses `stat`, and `fgetattrlist` to get the attributes.
    public func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                              of item: FSItem,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        guard let ptItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast item")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        let oldItemFD = ptItem.fileDescriptor
        if oldItemFD == -1 {
            do {
                try ptItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                Logger.ghosttreefs.error("\(#function): Can't open given item (\(ptItem.name)) error (\(error))")
                return replyHandler(nil, error)
            }
        }

        var statResult = stat()
        if fstat(ptItem.fileDescriptor, &statResult) == -1 {
            replyHandler(nil, posixErrno)
            if oldItemFD == -1 {
                try? ptItem.closeItem()
            }
            return
        }

        var commonAttrsBuf: CommonAttributes
        do {
            commonAttrsBuf = try self.getCommonAttributes(ptItem: ptItem, desiredAttributes: desiredAttributes)
        } catch {
            Logger.ghosttreefs.error("\(#function): Can't get commont attributes for item (\(ptItem.name))")
            replyHandler(nil, error)
            if oldItemFD == -1 {
                try? ptItem.closeItem()
            }
            return
        }

        let attrs = FSItem.Attributes()

        if desiredAttributes.isAttributeWanted(.uid) {
            attrs.uid = statResult.st_uid
        }

        if desiredAttributes.isAttributeWanted(.gid) {
            attrs.gid = statResult.st_gid
        }

        if desiredAttributes.isAttributeWanted(.mode) {
            attrs.mode = UInt32(Int32(statResult.st_mode) & modeAllBits)
        }

        if desiredAttributes.isAttributeWanted(.linkCount) {
            attrs.linkCount = UInt32(statResult.st_nlink)
        }

        if desiredAttributes.isAttributeWanted(.flags) {
            attrs.flags = statResult.st_flags
        }

        if desiredAttributes.isAttributeWanted(.size) {
            attrs.size = UInt64(statResult.st_size)
        }

        if desiredAttributes.isAttributeWanted(.allocSize) {
            attrs.allocSize = UInt64(statResult.st_blocks) * UInt64(statResult.st_blksize)
        }

        if desiredAttributes.isAttributeWanted(.fileID) {
            attrs.fileID = FSItem.Identifier(rawValue: ptItem.inode) ?? .invalid
        }

        if desiredAttributes.isAttributeWanted(.parentID) {
            attrs.parentID = FSItem.Identifier(rawValue: ptItem.parent?.inode ?? self.rootItem.inode) ?? .invalid
        }

        if desiredAttributes.isAttributeWanted(.type) {
            attrs.type = ptItem.itemType
        }

        var timeSpec: timespec

        if desiredAttributes.isAttributeWanted(.accessTime) {
            timeSpec = statResult.st_atimespec
            attrs.accessTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.changeTime) {
            timeSpec = statResult.st_ctimespec
            attrs.changeTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.modifyTime) {
            timeSpec = statResult.st_mtimespec
            attrs.modifyTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.addedTime) {
            timeSpec = commonAttrsBuf.addedTime
            attrs.addedTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.birthTime) {
            timeSpec = statResult.st_birthtimespec
            attrs.birthTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.backupTime) {
            timeSpec = commonAttrsBuf.backupTime
            attrs.backupTime = timeSpec
        }

        replyHandler(attrs, nil)

        if oldItemFD == -1 {
            try? ptItem.closeItem()
        }
    }

    /// Set item attributes.
    /// The method uses `ftruncate`, `fchmod`, `futimes`, `fchown`, and `fchflags`  to set the attributes.
    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                              on item: FSItem,
                              creatingNewFile: Bool,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        guard let ptItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast item")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        // Check that this request doesn't attempt to change read-only fields, raising an error if it does.
        if (creatingNewFile == false) &&
            (newAttributes.isValid(.type) || newAttributes.isValid(.linkCount) ||
             newAttributes.isValid(.allocSize) || newAttributes.isValid(.fileID) ||
             newAttributes.isValid(.parentID) || newAttributes.isValid(.changeTime)) {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        if newAttributes.isValid(.mode) && ((Int32(newAttributes.mode) & ~modeAllBits) != 0) {
            // Bits outside of the supported mode bits are specified.
            Logger.ghosttreefs.error("\(#function): Invalid mode bits for item (\(ptItem.name)), returning EINVAL")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        do {
            try self.prepareForMutation(ptItem)
        } catch {
            return replyHandler(nil, error)
        }

        var getAttrs: FSItem.Attributes?
        var getAttrsError: Error?
        let getAttrRequest: FSItem.GetAttributesRequest = FSItem.GetAttributesRequest()
        getAttrRequest.wantedAttributes = [.gid, .uid, .mode, .size, .allocSize,
                                           .type, .fileID, .parentID, .flags,
                                           .linkCount, .accessTime, .birthTime,
                                           .modifyTime, .changeTime]

        if newAttributes.isValid(.accessTime) ||
            newAttributes.isValid(.modifyTime) ||
            newAttributes.isValid(.uid)        ||
            newAttributes.isValid(.gid) {
            self.getAttributes(getAttrRequest, of: item) { (attrs, error) in
                getAttrsError = error
                getAttrs = attrs
            }
            if getAttrsError != nil {
                return replyHandler(nil, getAttrsError)
            }
        }

        let oldItemFD = ptItem.fileDescriptor
        if oldItemFD == -1 {
            do {
                try ptItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                Logger.ghosttreefs.error("\(#function): Can't upgrade item (\(ptItem.name)) to set item attributes")
                return replyHandler(nil, error)
            }
        }

        if newAttributes.isValid(.size) {
            if ptItem.itemType != FSItem.ItemType.file {
                Logger.ghosttreefs.error("\(#function): Can't change size of non file item (\(ptItem))")
                return replyHandler(nil, fs_errorForPOSIXError(EPERM))
            }
            do {
                try ptItem.upgradeOpenMode(mode: .readWrite)
            } catch {
                Logger.ghosttreefs.error("\(#function): Can't upgrade item (\(ptItem.name)) to ftruncate")
                return replyHandler(nil, error)
            }
            if ftruncate(ptItem.fileDescriptor, Int64(newAttributes.size)) < 0 {
                replyHandler(nil, posixErrno)
                if oldItemFD == -1 {
                    try? ptItem.closeItem()
                }
                return
            }
        }

        if newAttributes.isValid(.mode) {
            let updatedMode = ((Int32(newAttributes.mode) & modeAllBits))
            if fchmod(ptItem.fileDescriptor, mode_t(updatedMode)) < 0 {
                return replyHandler(nil, posixErrno)
            }
        }

        if newAttributes.isValid(.accessTime) || newAttributes.isValid(.modifyTime) {
            let times = UnsafeMutablePointer<timeval>.allocate(capacity: 2)
            var accessTime = timespec(tv_sec: 0, tv_nsec: 0)
            var modifyTime = timespec(tv_sec: 0, tv_nsec: 0)

            if newAttributes.isValid(.accessTime) {
                accessTime = newAttributes.accessTime
            } else {
                accessTime = getAttrs!.accessTime
            }

            if newAttributes.isValid(.modifyTime) {
                modifyTime = newAttributes.modifyTime
            } else {
                modifyTime = getAttrs!.modifyTime
            }

            times[0] = timeval(tv_sec: accessTime.tv_sec, tv_usec: (__darwin_suseconds_t)(accessTime.tv_nsec / 1000))
            times[1] = timeval(tv_sec: modifyTime.tv_sec, tv_usec: (__darwin_suseconds_t)(modifyTime.tv_nsec / 1000))
            do {
                try ptItem.upgradeOpenMode(mode: .readWrite)
            } catch {
                Logger.ghosttreefs.error("\(#function): Can't upgrade item (\(ptItem.name)) to set futimes")
                return replyHandler(nil, error)
            }
            if futimes(ptItem.fileDescriptor, times) < 0 {
                replyHandler(nil, posixErrno)
                if oldItemFD == -1 {
                    try? ptItem.closeItem()
                }
                return
            }
            times.deallocate()
        }

        if newAttributes.isValid(.flags) {
            let supportedBSDFlags = (UF_IMMUTABLE | UF_HIDDEN)
            if newAttributes.flags & ~UInt32(supportedBSDFlags) != 0 {
                Logger.ghosttreefs.error("\(#function): invalid BSD flags (\(newAttributes.flags))")
                replyHandler(nil, fs_errorForPOSIXError(EINVAL))
                if oldItemFD == -1 {
                    try? ptItem.closeItem()
                }
                return
            }
            if fchflags(ptItem.fileDescriptor, newAttributes.flags) < 0 {
                replyHandler(nil, posixErrno)
                if oldItemFD == -1 {
                    try? ptItem.closeItem()
                }
                return
            }
        }

        // Change the owner attribute last, since doing so earlier may prevent changing other things.
        if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
            var newUid: uid_t = 0
            var newGid: gid_t = 0

            if newAttributes.isValid(.uid) {
                newUid = newAttributes.uid
            } else {
                newUid = getAttrs!.uid
            }

            newGid = newAttributes.isValid(.gid) ? newAttributes.gid : getAttrs!.gid

            if fchown(ptItem.fileDescriptor, newUid, newGid) < 0 {
                replyHandler(nil, posixErrno)
                if oldItemFD == -1 {
                    try? ptItem.closeItem()
                }
                return
            }
        }

        self.getAttributes(getAttrRequest, of: item) { (attrs, error) in
            getAttrsError = error
            getAttrs = attrs
        }
        replyHandler(getAttrs, getAttrsError)

        if oldItemFD == -1 {
            try? ptItem.closeItem()
        }
    }

    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                              on item: FSItem,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        return self.setAttributes(newAttributes, on: item, creatingNewFile: false, replyHandler: replyHandler)
    }

    /// Performs a lookup on the given directory for the given name.
    /// Lookup is done by `fstatat`. If the item isn't in in the volume's item cache,  add it.
    /// - Parameters:
    ///   - name: The name of the item to lookup.
    ///   - directory: The directory to search.
    ///   - replyHandler: The handler to call when the lookup is complete.
    public func lookupItem(named name: FSFileName,
                           inDirectory directory: FSItem,
                           replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard let dirItem = directory as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast directory")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        guard let nameString = name.string else {
            Logger.ghosttreefs.error("\(#function): Can't cast name to string")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        let path: RelativePath
        do {
            path = try dirItem.relativePath.appending(nameString)
            var cached: GhosttreeFSItem?
            self.itemCacheQueue.sync {
                cached = self.itemCache.values.first { $0.relativePath == path }
            }
            if let cached {
                guard let entry = self.overlay.entry(at: path) else {
                    return replyHandler(nil, nil, POSIXError(.ENOENT))
                }
                if cached.backingURL != entry.url {
                    try cached.rebind(to: entry.url)
                }
                return replyHandler(cached, name, nil)
            }
        } catch {
            return replyHandler(nil, nil, error)
        }

        do {
            let newItem = try self.item(at: path, parent: dirItem)
            self.itemCacheQueue.sync {
                self.itemCache[newItem.inode] = newItem
            }
            return replyHandler(newItem, name, nil)
        } catch {
            Logger.ghosttreefs.error("\(#function): Can't create new item (\(name.debugDescription)) error (\(error)")
            return replyHandler(nil, nil, error)
        }
    }

    /// Performs reclamation of an item, by removing the item from the item cache, and closing it.
    /// - Parameters:
    ///   - item: The item to be reclaimed.
    ///   - replyHandler: The reply handler to invoke.
    public func reclaimItem(_ item: FSItem, replyHandler: @escaping (Error?) -> Void) {
        guard let ptItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }

        _ = self.itemCacheQueue.sync {
            self.itemCache.removeValue(forKey: ptItem.inode)
        }
        do {
            try ptItem.closeItem()
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Reads a symbolic link, by calling `freadlink`.
    /// - Parameters
    ///   - item: The item to be read.
    ///   - replyHandler: The reply handler to invoke.
    public func readSymbolicLink(_ item: FSItem,
                                 replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        guard let ptItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast item")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            try? ptItem.upgradeOpenMode(mode: .readOnly)
        }
        let buf = UnsafeMutablePointer<UTF8>.allocate(capacity: maxSymlinkSize)
        let bytesRead = freadlink(ptItem.fileDescriptor, buf, maxSymlinkSize)
        if bytesRead < 0 {
            buf.deallocate()
            replyHandler(nil, posixErrno)
            if oldFD < 0 {
                try? ptItem.closeItem()
            }
            return
        }
        let data = Data(bytes: buf, count: bytesRead)
        buf.deallocate()
        replyHandler(FSFileName(data: data), nil)
        if oldFD < 0 {
            try? ptItem.closeItem()
        }
    }

    /// Performs the creation of a new item in the specified directory, using `mkdirat` and `openat`.
    /// - Parameters:
    ///   - name: The name of the item to create.
    ///   - type: The type of the item to create.
    ///   - directory: The directory in which to create the item.
    ///   - newAttributes: The attributes of the new item.
    ///   - replyHandler: The reply handler to invoke.
    public func createItem(named name: FSFileName,
                           type: FSItem.ItemType,
                           inDirectory directory: FSItem,
                           attributes newAttributes: FSItem.SetAttributesRequest,
                           replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard let dirItem = directory as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast dirItem")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        guard let nameString = name.string else {
            Logger.ghosttreefs.error("\(#function): Invalid name string (\(name.debugDescription))")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        if (type == .file || type == .symlink) && !newAttributes.isValid(.mode) {
            Logger.ghosttreefs.error("\(#function): attributes doesn't contain a valid mode.")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        let path: RelativePath
        let newItem: GhosttreeFSItem
        do {
            path = try dirItem.relativePath.appending(nameString)
            switch type {
            case .directory:
                try overlay.createDirectory(at: path)
            case .file:
                _ = try overlay.createFile(at: path)
            default:
                throw POSIXError(.EINVAL)
            }
            newItem = try self.item(at: path, parent: dirItem)
        } catch {
            return replyHandler(nil, nil, error)
        }

        self.setAttributes(newAttributes, on: newItem, creatingNewFile: true, replyHandler: { (attrs, error) -> Void in
            guard error == nil else {
                return replyHandler(nil, nil, error)
            }
            self.itemCacheQueue.sync {
                self.itemCache[newItem.inode] = newItem
            }
            return replyHandler(newItem, name, error)
        })
    }

    /// Creates a new symbolic link using `symlinkat`.
    /// - Parameters:
    ///   - name: The name of the file to create.
    ///   - directory: The directory in which to create the symbolic link.
    ///   - newAttributes: The attributes to set on the newly created item.
    ///   - contents: The contents of the symbolic link.
    ///   - replyHandler: The handler to invoke when the operation completes.
    public func createSymbolicLink(named name: FSFileName,
                                   inDirectory directory: FSItem,
                                   attributes newAttributes: FSItem.SetAttributesRequest,
                                   linkContents contents: FSFileName,
                                   replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard contents.data.isEmpty == false else {
            Logger.ghosttreefs.error("\(#function): got invalid contents")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard let dirItem = directory as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast dirItem")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard dirItem.itemType == .directory else {
            Logger.ghosttreefs.error("\(#function): Invalid directory given")
            return replyHandler(nil, nil, POSIXError(.ENOTDIR))
        }
        guard newAttributes.isValid(.mode) != false else {
            Logger.ghosttreefs.error("\(#function): attributes don't contain a valid mode.")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard let nameString = name.string else {
            Logger.ghosttreefs.error("\(#function): Invalid name given")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        let newItem: GhosttreeFSItem
        do {
            let path = try dirItem.relativePath.appending(nameString)
            let contentsString = String(decoding: contents.data, as: Unicode.UTF8.self)
            _ = try overlay.createSymbolicLink(at: path, destination: contentsString)
            newItem = try self.item(at: path, parent: dirItem)
        } catch {
            return replyHandler(nil, nil, error)
        }

        self.setAttributes(newAttributes, on: newItem, creatingNewFile: true, replyHandler: { (attrs, error) -> Void in
            guard error == nil else {
                return replyHandler(nil, nil, error)
            }
            self.itemCacheQueue.sync {
                self.itemCache[newItem.inode] = newItem
            }
            return replyHandler(newItem, name, error)
        })
    }

    /// Creation of hard links aren't support for GhosttreeFS.
    public func createLink(to item: FSItem,
                           named name: FSFileName,
                           inDirectory directory: FSItem,
                           replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        return replyHandler(nil, POSIXError(.ENOTSUP))
    }

    /// Performs the actual removal of the given item from the given directory.
    /// - Parameters:
    ///   - item: The item to remove.
    ///   - name: The name of the item to remove.
    ///   - directory: The directory in which the item should be removed.
    ///   - replyHandler: The handler to call when the removal is complete.
    public func removeItem(_ item: FSItem,
                           named name: FSFileName,
                           fromDirectory directory: FSItem,
                           replyHandler: @escaping (Error?) -> Void) {
        guard directory is GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast dirItem")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard let ptItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard name.string != nil else {
            Logger.ghosttreefs.error("\(#function): Invalid name given")
            return replyHandler(POSIXError(.EINVAL))
        }

        do {
            try overlay.remove(ptItem.relativePath)
        } catch {
            return replyHandler(error)
        }

        // Remove from item cache the item.
        if ptItem.inode != 0 {
            _ = self.itemCacheQueue.sync {
                self.itemCache.removeValue(forKey: ptItem.inode)
            }
        }
        replyHandler(nil)
    }

    /// Performs a rename operation on a file system item.
    /// - Parameters:
    ///   - item: The file system item to rename.
    ///   - sourceDirectory: The directory containing the source file system item.
    ///   - sourceName: The name of the item to rename.
    ///   - destinationName: The name of the destination file system item.
    ///   - destinationDirectory: The directory to move the item into.
    ///   - overItem: The item that should be overwritten if it already exists.
    ///   - replyHandler: The reply handler to call when the operation is complete.
    public func renameItem(_ item: FSItem,
                           inDirectory sourceDirectory: FSItem,
                           named sourceName: FSFileName,
                           to destinationName: FSFileName,
                           inDirectory destinationDirectory: FSItem,
                           overItem: FSItem?,
                           replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        guard let fromItem = item as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast sourceName")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        guard let fromDir = sourceDirectory as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast sourceDirectory")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        guard let toDir = destinationDirectory as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast destinationDirectory")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        guard let sourceString = sourceName.string,
              let destinationString = destinationName.string else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        do {
            let sourcePath = try fromDir.relativePath.appending(sourceString)
            let destinationPath = try toDir.relativePath.appending(destinationString)
            try overlay.move(sourcePath, to: destinationPath)
            if let overwritten = overItem as? GhosttreeFSItem, overwritten !== fromItem {
                itemCacheQueue.sync { itemCache.removeValue(forKey: overwritten.inode) }
                try? overwritten.closeItem()
            }
            try self.relocateCachedItems(
                from: sourcePath,
                to: destinationPath,
                movedItem: fromItem,
                destinationParent: toDir
            )
            return replyHandler(destinationName, nil)
        } catch {
            return replyHandler(nil, error)
        }
    }

    /// Performs an enumeration of the contents of a directory.
    /// - Parameters:
    ///   - directory: The directory to enumerate.
    ///   - cookie: The cookie returned by a previous call to enumerateDirectory().
    ///   - verifier: The directory verifier.
    ///   - attributes: The attributes to request for each item in the directory.
    ///   - packer: The packer to use to serialize directory entries.
    ///   - replyHandler: The handler to call when the enumeration is complete.
    public func enumerateDirectory(_ directory: FSItem,
                                   startingAt cookie: FSDirectoryCookie,
                                   verifier: FSDirectoryVerifier,
                                   attributes: FSItem.GetAttributesRequest?,
                                   packer: FSDirectoryEntryPacker,
                                   replyHandler: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        guard let dirItem = directory as? GhosttreeFSItem else {
            Logger.ghosttreefs.error("\(#function): Can't cast directory")
            return replyHandler(FSDirectoryVerifier(0), POSIXError(.EINVAL))
        }

        if dirItem.itemType != .directory {
            Logger.ghosttreefs.error("\(#function): given item isn't a directory")
            return replyHandler(FSDirectoryVerifier(0), fs_errorForPOSIXError(ENOTDIR))
        }

        do {
            let names = try overlay.contentsOfDirectory(at: dirItem.relativePath)
            let startIndex = min(Int(cookie.rawValue), names.count)
            for index in startIndex..<names.count {
                let filename = names[index]
                let childPath = try dirItem.relativePath.appending(filename)
                let child = try self.item(at: childPath, parent: dirItem)
                var itemAttributes: FSItem.Attributes?
                if let attributes {
                    var attributeError: Error?
                    self.getAttributes(attributes, of: child) { result, error in
                        itemAttributes = result
                        attributeError = error
                    }
                    if let attributeError { throw attributeError }
                }
                let packed = packer.packEntry(
                    name: FSFileName(string: filename),
                    itemType: child.itemType,
                    itemID: FSItem.Identifier(rawValue: child.inode) ?? .invalid,
                    nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                    attributes: itemAttributes
                )
                if !packed { break }
            }
            return replyHandler(FSDirectoryVerifier(0), nil)
        } catch {
            return replyHandler(FSDirectoryVerifier(0), error)
        }
    }

    /// Returns `true` if the volume supports the specified capability, otherwise returns `false`.
    /// - Parameter capability: The capability to check.
    private func volumeSupportsCapability(capability: Int32) -> Bool {
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.volattr = UInt32(ATTR_VOL_CAPABILITIES)

        let lenSize = MemoryLayout<UInt32>.size
        let size = lenSize + MemoryLayout<vol_capabilities_attr_t>.size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4)
        defer { buffer.deallocate() }
        if fgetattrlist(self.rootItem.fileDescriptor, &attrs, buffer, size, 0) == -1 {
            return false
        }

        let attrPtr = (buffer + lenSize).assumingMemoryBound(to: vol_capabilities_attr_t.self)
        let validClone = (attrPtr.pointee.valid.1 & UInt32(capability)) != 0
        let capClone = (attrPtr.pointee.capabilities.1 & UInt32(capability)) != 0
        return validClone && capClone
    }

    /// The set of volume capabilities supported by this instance.
    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsSymbolicLinks                  = self.volumeSupportsCapability(capability: VOL_CAP_FMT_SYMBOLICLINKS)
        capabilities.supportsHardLinks                      = false
        capabilities.supportsHiddenFiles                    = self.volumeSupportsCapability(capability: VOL_CAP_FMT_HIDDEN_FILES)
        capabilities.supportsPersistentObjectIDs            = false
        capabilities.supportsJournal                        = false
        capabilities.supportsActiveJournal                  = false
        capabilities.supportsSparseFiles                    = self.volumeSupportsCapability(capability: VOL_CAP_FMT_SPARSE_FILES)
        capabilities.supportsZeroRuns                       = self.volumeSupportsCapability(capability: VOL_CAP_FMT_ZERO_RUNS)
        capabilities.supportsFastStatFS                     = self.volumeSupportsCapability(capability: VOL_CAP_FMT_FAST_STATFS)
        capabilities.supports2TBFiles                       = self.volumeSupportsCapability(capability: VOL_CAP_FMT_2TB_FILESIZE)
        capabilities.supportsOpenDenyModes                  = self.volumeSupportsCapability(capability: VOL_CAP_FMT_OPENDENYMODES)
        capabilities.supports64BitObjectIDs                 = self.volumeSupportsCapability(capability: VOL_CAP_FMT_64BIT_OBJECT_IDS)
        capabilities.supportsDocumentID                     = false
        capabilities.supportsSharedSpace                    = self.volumeSupportsCapability(capability: VOL_CAP_FMT_SHARED_SPACE)
        capabilities.supportsVolumeGroups                   = false
        capabilities.doesNotSupportVolumeSizes              = self.volumeSupportsCapability(capability: VOL_CAP_FMT_NO_VOLUME_SIZES)
        capabilities.doesNotSupportImmutableFiles           = self.volumeSupportsCapability(capability: VOL_CAP_FMT_NO_IMMUTABLE_FILES)
        capabilities.doesNotSupportRootTimes                = self.volumeSupportsCapability(capability: VOL_CAP_FMT_NO_ROOT_TIMES)
        capabilities.doesNotSupportSettingFilePermissions   = self.volumeSupportsCapability(capability: VOL_CAP_FMT_NO_PERMISSIONS)
        // Determine caseSensitivity:
        if self.volumeSupportsCapability(capability: VOL_CAP_FMT_CASE_SENSITIVE) {
            capabilities.caseFormat = FSVolume.CaseFormat.sensitive
        } else if self.volumeSupportsCapability(capability: VOL_CAP_FMT_CASE_PRESERVING) {
            capabilities.caseFormat = FSVolume.CaseFormat.insensitiveCasePreserving
        } else {
            capabilities.caseFormat = FSVolume.CaseFormat.insensitive
        }
        return capabilities
    }

}
