// dmg_layout.swift
//
// Writes the Finder window layout (.DS_Store) of the root folder of a mounted,
// writable HFS+ disk image, so a release script can lay out a DMG on a headless
// Mac without Finder, AppleScript or third-party code. Foundation only.
//
// Usage:
//   swift dmg_layout.swift --volume <mount point> \
//     [--background .background/background.tiff] \
//     --window 200,120,640,432 [--icon-size 128] [--text-size 13] \
//     --item Kaern.app=170,200 --item Applications=470,200
//
//   --volume PATH       mount point of the volume (must be the volume's root).
//   --background PATH   background picture, relative to the volume (or an
//                       absolute path inside it). Without it the window has
//                       Finder's default background.
//   --window X,Y,W,H    Finder's WindowBounds: the whole window frame, title bar
//                       included, in points; X,Y is the frame's bottom-left
//                       corner, Y counted up from the bottom of the main screen.
//                       For a W x H picture, use height H + the title bar
//                       (32 pt for a standard title bar on macOS 27).
//   --icon-size N       icon size in points (default 128).
//   --text-size N       label text size in points (default 13).
//   --item NAME=X,Y     center of NAME's icon, in points from the top-left of
//                       the window's content area (repeatable). NAME is an
//                       entry at the top level of the volume.
//
// What it writes (the records dmgbuild writes, plus pBBk and vstl):
//   "."    bwsp  blob  binary plist: WindowBounds, Show* flags, SidebarWidth
//   "."    icvl  type  icnv
//   "."    icvp  blob  binary plist: icon view options; backgroundImageAlias
//                      is an Alias record (version 2) of the background file
//   "."    pBBk  blob  bookmark data of the background file (URL.bookmarkData)
//   "."    vSrn  long  1
//   "."    vstl  type  icnv  (Finder's "Always open in icon view")
//   NAME   Iloc  blob  x, y, then ff ff ff ff ff ff 00 00
//
// File layout: the buddy allocator ("Bud1" header, bookkeeping block with the
// block address table, the "DSDB" directory entry and the 32 free lists), the
// DSDB header block, and one B-tree leaf node holding every record, sorted by
// file name (case-insensitively), then by record code. The script fails if the
// records do not fit in one 4096-byte node.

import Foundation
import Darwin

struct LayoutError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Big-endian writer

struct ByteWriter {
    private(set) var data = Data()

    var count: Int { data.count }

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 { data.append(contentsOf: bytes) }
    mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: n)) }

    /// A four-character code: exactly four ASCII bytes.
    mutating func code(_ fourCC: String) {
        let ascii = Array(fourCC.utf8)
        precondition(ascii.count == 4, "four-character code expected: \(fourCC)")
        data.append(contentsOf: ascii)
    }

    /// A Pascal string in a fixed field of `capacity` bytes (length byte included).
    mutating func pascal(_ bytes: [UInt8], capacity: Int) {
        let body = bytes.prefix(capacity - 1)
        u8(UInt8(body.count))
        data.append(contentsOf: body)
        zeros(capacity - 1 - body.count)
    }

    mutating func patchU16(at offset: Int, _ value: UInt16) {
        data[offset] = UInt8(value >> 8)
        data[offset + 1] = UInt8(value & 0xff)
    }
}

// MARK: - DS_Store records

enum RecordValue {
    case long(UInt32)
    case type(String)
    case blob(Data)
}

struct Record {
    let name: String    // file name in the folder, "." for the folder itself
    let code: String    // structure ID, e.g. "Iloc"
    let value: RecordValue

    func write(into w: inout ByteWriter) {
        let units = Array(name.utf16)
        w.u32(UInt32(units.count))
        for unit in units { w.u16(unit) }
        w.code(code)
        switch value {
        case .long(let v):
            w.code("long"); w.u32(v)
        case .type(let t):
            w.code("type"); w.code(t)
        case .blob(let d):
            w.code("blob"); w.u32(UInt32(d.count)); w.bytes(d)
        }
    }

    /// Finder's order: file name compared case-insensitively, then the record code.
    static func finderOrder(_ a: Record, _ b: Record) -> Bool {
        let an = Array(a.name.lowercased().utf16), bn = Array(b.name.lowercased().utf16)
        if an != bn { return an.lexicographicallyPrecedes(bn) }
        return Array(a.code.utf8).lexicographicallyPrecedes(Array(b.code.utf8))
    }
}

// MARK: - Buddy allocator and file layout

/// The allocator manages a 2^31-byte space; a block of width w is 2^w bytes at a
/// 2^w-aligned offset. Offsets are relative to file byte 4.
struct BuddyAllocator {
    private(set) var free: [[UInt32]] = Array(repeating: [], count: 32)

    init() { free[31] = [0] }

    static func width(for bytes: Int) -> Int {
        var w = 5
        while (1 << w) < bytes { w += 1 }
        return w
    }

    /// Takes the lowest free block of the smallest sufficient width, splitting
    /// larger blocks; the upper halves stay free.
    mutating func allocate(width: Int) throws -> UInt32 {
        guard let found = (width...31).first(where: { !free[$0].isEmpty }) else {
            throw LayoutError("allocator: no free block of width \(width)")
        }
        let offset = free[found].removeFirst()
        var w = found
        while w > width {
            w -= 1
            free[w].append(offset + (UInt32(1) << UInt32(w)))
            free[w].sort()
        }
        return offset
    }
}

enum Constants {
    static let pageSize = 0x1000
    static let hfsEpochOffset: Int64 = 2_082_844_800   // seconds from 1904-01-01 to 1970-01-01 (UTC)
}

func makeDSStore(records unsorted: [Record]) throws -> Data {
    let records = unsorted.sorted(by: Record.finderOrder)

    // The B-tree: a single leaf node (P = 0, then the record count, then the records).
    var leaf = ByteWriter()
    leaf.u32(0)
    leaf.u32(UInt32(records.count))
    for record in records { record.write(into: &leaf) }
    guard leaf.count <= Constants.pageSize else {
        throw LayoutError("the records take \(leaf.count) bytes, more than one \(Constants.pageSize)-byte B-tree node, "
                          + "which is all this script writes (each --item takes about 50 bytes; the alias and "
                          + "bookmark grow with the mount point and disk image paths)")
    }

    var allocator = BuddyAllocator()
    let headerOffset = try allocator.allocate(width: 5)          // the "Bud1" header block
    precondition(headerOffset == 0)
    let dsdbWidth = 5, leafWidth = BuddyAllocator.width(for: Constants.pageSize), rootWidth = 11
    let dsdbOffset = try allocator.allocate(width: dsdbWidth)    // DSDB header (20 bytes)
    let leafOffset = try allocator.allocate(width: leafWidth)    // the leaf node
    let rootOffset = try allocator.allocate(width: rootWidth)    // bookkeeping block

    // Block IDs index the address table: 0 = bookkeeping, 1 = DSDB, 2 = leaf.
    let addresses: [UInt32] = [rootOffset | UInt32(rootWidth),
                               dsdbOffset | UInt32(dsdbWidth),
                               leafOffset | UInt32(leafWidth)]

    var root = ByteWriter()
    root.u32(UInt32(addresses.count))
    root.u32(0)
    for address in addresses { root.u32(address) }
    root.zeros(4 * (256 - addresses.count % 256) % 1024)           // pad to a multiple of 256 entries
    root.u32(1)                                                    // directory entries
    root.u8(4); root.code("DSDB"); root.u32(1)
    for list in allocator.free {                                   // free lists, widths 0...31
        root.u32(UInt32(list.count))
        for offset in list { root.u32(offset) }
    }
    guard root.count <= (1 << rootWidth) else { throw LayoutError("bookkeeping block too large") }

    var dsdb = ByteWriter()
    dsdb.u32(2)                         // block ID of the root node
    dsdb.u32(0)                         // internal levels (0: the root is a leaf)
    dsdb.u32(UInt32(records.count))     // records
    dsdb.u32(1)                         // nodes
    dsdb.u32(UInt32(Constants.pageSize))          // node page size

    var header = ByteWriter()
    header.code("Bud1")
    header.u32(rootOffset)
    header.u32(UInt32(1 << rootWidth))  // Finder stores the block size here
    header.u32(rootOffset)              // copy of the offset; Finder checks they match
    for address in addresses.dropFirst(2) { header.u32(address) }   // 16 unused bytes; Finder's
    header.zeros(16 - 4 * (addresses.count - 2))                       // files hold stale addresses

    let blocks: [(offset: UInt32, bytes: Data)] = [(0, header.data), (dsdbOffset, dsdb.data),
                                                   (leafOffset, leaf.data), (rootOffset, root.data)]
    let end = [Int(dsdbOffset) + (1 << dsdbWidth), Int(leafOffset) + (1 << leafWidth),
               Int(rootOffset) + (1 << rootWidth)].max()!
    var file = Data(count: 4 + end)
    file.replaceSubrange(0..<4, with: [0, 0, 0, 1])
    for block in blocks {
        let start = 4 + Int(block.offset)
        file.replaceSubrange(start..<(start + block.bytes.count), with: block.bytes)
    }
    return file
}

// MARK: - File system facts (getattrlist)

func hfsSeconds(_ t: timespec) -> UInt32 {
    UInt32(truncatingIfNeeded: Int64(t.tv_sec) + Constants.hfsEpochOffset)
}

/// Seconds since 1904 as a 48.16 fixed-point value, as in alias tags 16 and 17.
func hfsHighRes(_ t: timespec) -> UInt64 {
    UInt64(truncatingIfNeeded: (Int64(t.tv_sec) + Constants.hfsEpochOffset) << 16) + UInt64(t.tv_nsec) * 65536 / 1_000_000_000
}

func attributes(_ path: String, common: UInt32, volume: UInt32 = 0, options: UInt32 = 0) throws -> [UInt8] {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = common
    request.volattr = volume
    var buffer = [UInt8](repeating: 0, count: 4096)
    let status = buffer.withUnsafeMutableBytes { raw in
        getattrlist(path, &request, raw.baseAddress, raw.count, options)
    }
    guard status == 0 else { throw LayoutError("getattrlist \(path): \(String(cString: strerror(errno)))") }
    return buffer
}

func load<T>(_ buffer: [UInt8], _ offset: Int, as type: T.Type) -> T {
    buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
}

struct VolumeFacts {
    let mountPoint: String
    let name: String
    let created: timespec
    let fsType: String
}

struct ItemFacts {
    let isDirectory: Bool
    let created: timespec
    let finderInfo: [UInt8]   // 32 bytes as stored (big-endian)
    let fileID: UInt64        // CNID on HFS+
    let parentID: UInt64
}

func volumeFacts(_ path: String) throws -> VolumeFacts {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { throw LayoutError("statfs \(path): \(String(cString: strerror(errno)))") }
    let mountPoint = withUnsafeBytes(of: fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    let fsType = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    // Common attributes requested together with volume attributes describe the volume:
    // ATTR_CMN_CRTIME is then the volume creation date.
    let buf = try attributes(mountPoint, common: UInt32(ATTR_CMN_CRTIME),
                             volume: ATTR_VOL_INFO | UInt32(ATTR_VOL_NAME))
    let created = load(buf, 4, as: timespec.self)
    let nameRef = 4 + MemoryLayout<timespec>.size
    let nameOffset = Int(load(buf, nameRef, as: Int32.self))
    let nameLength = Int(load(buf, nameRef + 4, as: UInt32.self))
    let nameBytes = buf[(nameRef + nameOffset)..<(nameRef + nameOffset + nameLength)].prefix { $0 != 0 }
    return VolumeFacts(mountPoint: mountPoint, name: String(decoding: nameBytes, as: UTF8.self),
                       created: created, fsType: fsType)
}

func itemFacts(_ path: String) throws -> ItemFacts {
    let common = UInt32(ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_FNDRINFO | ATTR_CMN_FILEID | ATTR_CMN_PARENTID)
    let buf = try attributes(path, common: common, options: UInt32(FSOPT_NOFOLLOW))
    var offset = 4
    let objectType = load(buf, offset, as: UInt32.self); offset += 4
    let created = load(buf, offset, as: timespec.self); offset += MemoryLayout<timespec>.size
    let finderInfo = Array(buf[offset..<(offset + 32)]); offset += 32
    let fileID = load(buf, offset, as: UInt64.self); offset += 8
    let parentID = load(buf, offset, as: UInt64.self)
    return ItemFacts(isDirectory: objectType == 2 /* VDIR */, created: created,
                     finderInfo: finderInfo, fileID: fileID, parentID: parentID)
}

// MARK: - Alias record (version 2)

/// A classic (HFS) name: Mac OS Roman when it can be, else UTF-8; ':' becomes '/'.
func classicName(_ name: String) -> [UInt8] {
    let carbon = name.precomposedStringWithCanonicalMapping.replacingOccurrences(of: ":", with: "/")
    if let roman = carbon.data(using: .macOSRoman) { return Array(roman) }
    return Array(carbon.utf8)
}

/// An Alias record of `relativePath` (components below the volume root) on `volume`,
/// with the fields mac_alias's Alias.for_file writes.
func makeAlias(volume: VolumeFacts, relativePath components: [String]) throws -> Data {
    let path = volume.mountPoint + "/" + components.joined(separator: "/")
    let target = try itemFacts(path)

    // CNIDs of the folders between the volume root and the target, nearest first.
    var cnidPath: [UInt32] = []
    for depth in stride(from: components.count - 1, to: 0, by: -1) {
        let folder = volume.mountPoint + "/" + components[0..<depth].joined(separator: "/")
        cnidPath.append(UInt32(truncatingIfNeeded: try itemFacts(folder).fileID))
    }
    let fileName = components.last!
    let folderName = components.count > 1 ? components[components.count - 2] : volume.name

    var w = ByteWriter()
    w.zeros(4)                                       // application-specific (user type)
    w.u16(0)                                         // record size, patched below
    w.u16(2)                                         // version
    w.u16(target.isDirectory ? 1 : 0)                // kind: 0 file, 1 folder
    w.pascal(classicName(volume.name), capacity: 28) // volume name (Str27)
    w.u32(hfsSeconds(volume.created))                // volume creation date
    w.bytes(Array("H+".utf8))                        // file system type
    w.u16(0)                                         // disk type: fixed disk
    w.u32(UInt32(truncatingIfNeeded: target.parentID))
    w.pascal(classicName(fileName), capacity: 64)    // file name (Str63)
    w.u32(UInt32(truncatingIfNeeded: target.fileID))
    w.u32(hfsSeconds(target.created))                // target creation date
    if target.isDirectory {
        w.zeros(8)
    } else {
        w.bytes(target.finderInfo[0..<4])            // file type
        w.bytes(target.finderInfo[4..<8])            // creator
    }
    w.i16(-1)                                        // levels from the alias to the root
    w.i16(-1)                                        // levels from the root to the target
    w.u32(0)                                         // volume attributes
    w.u16(0)                                         // volume file system ID
    w.zeros(10)                                      // reserved

    func tag(_ tag: Int16, _ value: [UInt8]) {
        w.i16(tag)
        w.u16(UInt16(value.count))
        w.bytes(value)
        if value.count % 2 == 1 { w.u8(0) }
    }
    func unicode(_ s: String) -> [UInt8] {
        let units = Array(s.decomposedStringWithCanonicalMapping.replacingOccurrences(of: ":", with: "/").utf16)
        var v = ByteWriter()
        v.u16(UInt16(units.count))
        for unit in units { v.u16(unit) }
        return Array(v.data)
    }
    func u64(_ x: UInt64) -> [UInt8] { var v = ByteWriter(); v.u64(x); return Array(v.data) }

    tag(0, classicName(folderName))                                    // parent folder name
    tag(16, u64(hfsHighRes(volume.created)))                           // volume creation date, 48.16
    tag(17, u64(hfsHighRes(target.created)))                           // target creation date, 48.16
    if !cnidPath.isEmpty {
        var v = ByteWriter()
        for cnid in cnidPath { v.u32(cnid) }
        tag(1, Array(v.data))                                          // CNID path
    }
    let carbonPath = ([volume.name] + components).map { classicName($0) }
    tag(2, Array(carbonPath.joined(separator: [UInt8(ascii: ":")])))    // "Kaern:.background:background.tiff"
    tag(14, unicode(fileName))                                         // Unicode file name
    tag(15, unicode(volume.name))                                      // Unicode volume name
    tag(18, Array(("/" + components.joined(separator: "/")).utf8))     // POSIX path within the volume
    tag(19, Array(volume.mountPoint.utf8))                             // POSIX path of the mount point
    w.i16(-1); w.u16(0)                                                // end

    guard w.count <= Int(UInt16.max) else { throw LayoutError("alias record too large") }
    w.patchU16(at: 4, UInt16(w.count))
    return w.data
}

// MARK: - Plists

func binaryPlist(_ dictionary: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
}

// MARK: - Command line

struct Options {
    var volume: String?
    var background: String?
    var window: [Int]?
    var iconSize: Double = 128
    var textSize: Double = 13
    var items: [(name: String, x: UInt32, y: UInt32)] = []
}

enum Help {
    static let usage = """
usage: swift dmg_layout.swift --volume <mount point> [--background <path in volume>]
         --window x,y,w,h [--icon-size 128] [--text-size 13] --item NAME=x,y ...
  --window is Finder's WindowBounds: the whole window frame (title bar included),
  x,y = bottom-left corner, y counted up from the bottom of the main screen.
  --item positions are icon centers, in points from the top-left of the content area.
"""
}

func numbers(_ text: String, count: Int, option: String) throws -> [Int] {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        .map { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == count, parts.allSatisfy({ $0 != nil }) else {
        throw LayoutError("\(option) expects \(count) comma-separated integers, got \"\(text)\"")
    }
    return parts.map { $0! }
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var rest = arguments[...]
    func value(_ option: String) throws -> String {
        guard let v = rest.popFirst() else { throw LayoutError("\(option) needs a value") }
        return v
    }
    while let argument = rest.popFirst() {
        switch argument {
        case "--volume": options.volume = try value(argument)
        case "--background": options.background = try value(argument)
        case "--window":
            let v = try numbers(try value(argument), count: 4, option: argument)
            guard v[2] > 0, v[3] > 0 else { throw LayoutError("--window width and height must be positive") }
            options.window = v
        case "--icon-size":
            guard let v = Double(try value(argument)), (16...512).contains(v) else { throw LayoutError("--icon-size expects 16...512") }
            options.iconSize = v
        case "--text-size":
            guard let v = Double(try value(argument)), (10...16).contains(v) else { throw LayoutError("--text-size expects 10...16") }
            options.textSize = v
        case "--item":
            let v = try value(argument)
            guard let eq = v.lastIndex(of: "="), eq != v.startIndex else { throw LayoutError("--item expects NAME=x,y, got \"\(v)\"") }
            let name = String(v[..<eq])
            let xy = try numbers(String(v[v.index(after: eq)...]), count: 2, option: argument)
            guard xy.allSatisfy({ $0 >= 0 }) else { throw LayoutError("--item positions must not be negative") }
            options.items.append((name, UInt32(xy[0]), UInt32(xy[1])))
        case "-h", "--help":
            print(Help.usage); exit(0)
        default:
            throw LayoutError("unknown argument \"\(argument)\"\n\(Help.usage)")
        }
    }
    return options
}

func run() throws {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    guard let volumeArgument = options.volume, let window = options.window else {
        throw LayoutError("--volume and --window are required\n\(Help.usage)")
    }

    // The volume: must be the root of a mounted, writable file system.
    guard let resolved = realpath(volumeArgument, nil) else {
        throw LayoutError("\(volumeArgument): \(String(cString: strerror(errno)))")
    }
    let volumePath = String(cString: resolved); free(resolved)
    let volume = try volumeFacts(volumePath)
    guard volume.mountPoint == volumePath else {
        throw LayoutError("\(volumePath) is not a mount point (it is inside \(volume.mountPoint))")
    }
    guard access(volumePath, W_OK) == 0 else { throw LayoutError("\(volumePath) is not writable") }
    if volume.fsType != "hfs" {
        FileHandle.standardError.write(Data("warning: \(volumePath) is \(volume.fsType), not HFS+; the alias still says H+\n".utf8))
    }

    // Items: top-level entries, named as they are on disk.
    let entries = try FileManager.default.contentsOfDirectory(atPath: volumePath)
    var records: [Record] = []
    var seen = Set<String>()
    for item in options.items {
        guard !item.name.contains("/"), item.name != ".", item.name != ".." else {
            throw LayoutError("--item \(item.name): only entries at the top level of the volume")
        }
        guard let onDisk = entries.first(where: { $0.lowercased() == item.name.lowercased() }) else {
            throw LayoutError("--item \(item.name): no such entry in \(volumePath)")
        }
        guard seen.insert(onDisk.lowercased()).inserted else { throw LayoutError("--item \(item.name) given twice") }
        var iloc = ByteWriter()
        iloc.u32(item.x); iloc.u32(item.y)
        iloc.u32(0xFFFF_FFFF); iloc.u32(0xFFFF_0000)
        records.append(Record(name: onDisk, code: "Iloc", value: .blob(iloc.data)))
    }

    // Window.
    let bwsp: [String: Any] = [
        "WindowBounds": "{{\(window[0]), \(window[1])}, {\(window[2]), \(window[3])}}",
        "ShowToolbar": false, "ShowSidebar": false, "ShowStatusBar": false, "ShowPathbar": false,
        "ShowTabView": false, "ContainerShowSidebar": false, "PreviewPaneVisibility": false,
        "SidebarWidth": 180,
    ]
    records.append(Record(name: ".", code: "bwsp", value: .blob(try binaryPlist(bwsp))))

    // Icon view.
    var icvp: [String: Any] = [
        "viewOptionsVersion": 1, "backgroundType": 0,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "iconSize": options.iconSize, "textSize": options.textSize,
        "arrangeBy": "none", "labelOnBottom": true, "showItemInfo": false, "showIconPreview": false,
        "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    ]
    var aliasSize = 0, bookmarkSize = 0
    if let background = options.background {
        let joined = background.hasPrefix("/") ? background : volumePath + "/" + background
        guard let real = realpath(joined, nil) else { throw LayoutError("--background \(background): \(String(cString: strerror(errno)))") }
        let backgroundPath = String(cString: real); free(real)
        guard backgroundPath.hasPrefix(volumePath + "/") else {
            throw LayoutError("--background \(background) is not inside \(volumePath)")
        }
        var st = stat()
        guard stat(backgroundPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw LayoutError("--background \(background) is not a regular file")
        }
        let components = backgroundPath.dropFirst(volumePath.count + 1).split(separator: "/").map(String.init)
        let alias = try makeAlias(volume: volume, relativePath: components)
        icvp["backgroundType"] = 2
        icvp["backgroundImageAlias"] = alias
        // Without the implicit security scope: the sandbox extension tokens it adds (~640 bytes)
        // only work on the machine that made them. Resolution is the same either way.
        let bookmark = try URL(fileURLWithPath: backgroundPath)
            .bookmarkData(options: [.withoutImplicitSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        records.append(Record(name: ".", code: "pBBk", value: .blob(bookmark)))
        aliasSize = alias.count; bookmarkSize = bookmark.count
    }
    records.append(Record(name: ".", code: "icvp", value: .blob(try binaryPlist(icvp))))
    records.append(Record(name: ".", code: "icvl", value: .type("icnv")))
    records.append(Record(name: ".", code: "vstl", value: .type("icnv")))
    records.append(Record(name: ".", code: "vSrn", value: .long(1)))

    let store = try makeDSStore(records: records)
    let storePath = volumePath + "/.DS_Store"
    let fd = open(storePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { throw LayoutError("\(storePath): \(String(cString: strerror(errno)))") }
    let written = store.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    let synced = fsync(fd)
    close(fd)
    guard written == store.count, synced == 0 else { throw LayoutError("\(storePath): write failed") }

    print("wrote \(storePath): \(store.count) bytes, \(records.count) records"
          + (options.background != nil ? " (alias \(aliasSize) bytes, bookmark \(bookmarkSize) bytes)" : ""))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("dmg_layout: \(error)\n".utf8))
    exit(1)
}
