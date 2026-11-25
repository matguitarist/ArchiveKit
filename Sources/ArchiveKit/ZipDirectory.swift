import Compression
import Foundation

extension Zip {
    /// One entry of a zip, read from its central directory without unpacking anything.
    public struct Entry: Sendable, Hashable {
        /// The path inside the zip, with "/" between folders ("Game/game/script.rpy"; "Game/" for a folder).
        public let name: String
        /// Uncompressed size in bytes.
        public let size: UInt64
        public let compressedSize: UInt64
        /// 0 stored, 8 deflate; others are read by unzip.
        public let method: UInt16
        public let crc32: UInt32
        public let isDirectory: Bool
        public let isSymlink: Bool
        /// Where a symbolic link points, as stored in the zip.
        public let linkTarget: String?
        /// Where its local header starts, and its general-purpose flags (bit 0: encrypted).
        var offset: UInt64 = 0
        var flags: UInt16 = 0
        /// Made by macOS for a resource fork or Finder info (__MACOSX/, ._name).
        public var isMacMetadata: Bool {
            name.hasPrefix("__MACOSX/") || name.split(separator: "/").last?.hasPrefix("._") == true
        }
    }

    /// Reads the central directory (ZIP64 too) of a zip file.
    static func readDirectory(_ url: URL) throws(ArchiveError) -> [Entry] {
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw .notAZip(size: 0) }
        guard data.count >= 4, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B else {
            throw .notAZip(size: Int64(data.count))
        }
        guard data.count >= 22 else { throw .damaged("too short") }

        // The end record is in the last 64 KB (a comment is at most that).
        var end = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while end >= floor, data.le32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= floor else { throw .damaged("no end record") }
        var count = UInt64(data.le16(end + 10))
        var directorySize = UInt64(data.le32(end + 12))
        var directoryOffset = UInt64(data.le32(end + 16))
        // ZIP64: saturated fields, and a locator 20 bytes before the end record.
        let locator = end - 20
        let hasLocator = locator >= 0 && data.le32(locator) == 0x0706_4b50
        if directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF, !hasLocator { throw .damaged("no ZIP64 locator") }
        if hasLocator, count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            let record = data.le64(locator + 8)
            guard record + 56 <= UInt64(data.count), data.le32(Int(record)) == 0x0606_4b50 else { throw .damaged("no ZIP64 record") }
            count = data.le64(Int(record) + 32)
            directorySize = data.le64(Int(record) + 40)
            directoryOffset = data.le64(Int(record) + 48)
        }
        guard directoryOffset + directorySize <= UInt64(data.count) else { throw .damaged("directory past the end") }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(count, 1_000_000)))
        var at = Int(directoryOffset)
        for _ in 0..<count {
            guard at + 46 <= data.count, data.le32(at) == 0x0201_4b50 else { throw .damaged("bad directory record") }
            let madeBy = data[data.startIndex + at + 5]
            let flags = data.le16(at + 8)
            let method = data.le16(at + 10)
            let crc = data.le32(at + 16)
            var compressed = UInt64(data.le32(at + 20))
            var size = UInt64(data.le32(at + 24))
            let nameLength = Int(data.le16(at + 28))
            let extraLength = Int(data.le16(at + 30))
            let commentLength = Int(data.le16(at + 32))
            let external = data.le32(at + 38)
            var local = UInt64(data.le32(at + 42))
            guard at + 46 + nameLength + extraLength + commentLength <= data.count else { throw .damaged("record past the end") }
            let nameStart = data.startIndex + at + 46
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            // ZIP64 extra field: only the saturated values, in this order.
            var x = at + 46 + nameLength
            let extraEnd = x + extraLength
            while x + 4 <= extraEnd {
                let id = data.le16(x), length = Int(data.le16(x + 2))
                if id == 0x0001 {
                    var q = x + 4
                    if size == 0xFFFF_FFFF, q + 8 <= extraEnd { size = data.le64(q); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= extraEnd { compressed = data.le64(q); q += 8 }
                    if local == 0xFFFF_FFFF, q + 8 <= extraEnd { local = data.le64(q) }
                }
                x += 4 + length
            }
            // Unix (3) and macOS (19) keep the file type in the top half of the external attributes.
            let mode = (madeBy == 3 || madeBy == 19) ? (external >> 16) & 0o170000 : 0
            let isSymlink = mode == 0o120000
            let isDirectory = name.hasSuffix("/") || name.hasSuffix("\\") || mode == 0o040000
            let target = isSymlink ? linkTarget(in: data, localHeader: local, method: method, compressedSize: compressed, size: size) : nil
            entries.append(Entry(name: name, size: size, compressedSize: compressed, method: method, crc32: crc,
                                 isDirectory: isDirectory, isSymlink: isSymlink, linkTarget: target, offset: local, flags: flags))
            at = extraEnd + commentLength
        }
        return entries
    }

    /// A symbolic link's target: its entry's data, stored or deflated. Nil when it can't be read,
    /// which counts as unsafe.
    private static func linkTarget(in data: Data, localHeader: UInt64, method: UInt16, compressedSize: UInt64, size: UInt64) -> String? {
        guard size <= 4096, compressedSize <= 64 * 1024, localHeader + 30 <= UInt64(data.count) else { return nil }
        let local = Int(localHeader)
        guard data.le32(local) == 0x0403_4b50 else { return nil }
        let start = local + 30 + Int(data.le16(local + 26)) + Int(data.le16(local + 28))
        guard start + Int(compressedSize) <= data.count else { return nil }
        let bytes = data[(data.startIndex + start)..<(data.startIndex + start + Int(compressedSize))]
        switch method {
        case 0:
            return String(decoding: bytes, as: UTF8.self)
        case 8:
            guard size > 0 else { return "" }
            var output = [UInt8](repeating: 0, count: Int(size))
            let source = [UInt8](bytes)
            // COMPRESSION_ZLIB is raw DEFLATE, what zip's method 8 stores.
            let written = compression_decode_buffer(&output, output.count, source, source.count, nil, COMPRESSION_ZLIB)
            guard written == Int(size) else { return nil }
            return String(decoding: output, as: UTF8.self)
        default:
            return nil
        }
    }
}

extension Data {
    func le16(_ i: Int) -> UInt16 { UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8 }
    func le32(_ i: Int) -> UInt32 { UInt32(le16(i)) | UInt32(le16(i + 2)) << 16 }
    func le64(_ i: Int) -> UInt64 { UInt64(le32(i)) | UInt64(le32(i + 4)) << 32 }
}
