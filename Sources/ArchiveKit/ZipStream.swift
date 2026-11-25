import Compression
import CryptoKit
import Foundation
import ProcessKit

extension Zip {
    /// The file entry with that exact name.
    static func entry(named name: String, in zip: URL) throws -> Entry {
        guard let found = try entries(zip).first(where: { $0.name == name && !$0.isDirectory }) else { throw ArchiveError.missingEntry(name) }
        return found
    }

    /// An entry's bytes in chunks of at most 1 MB, checked against its size and CRC at the end. Stored and
    /// deflated entries (nearly all) are read straight from the zip; other methods go through unzip.
    static func stream(_ entry: Entry, in zip: URL, stop: Shell.CancelFlag, _ chunk: (Data) throws -> Void) throws {
        guard entry.flags & 1 == 0, entry.method == 0 || entry.method == 8 else {
            try streamWithUnzip(entry, in: zip, stop: stop, chunk)
            return
        }
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.offset)
        guard let header = try handle.read(upToCount: 30), header.count == 30, header.le32(0) == 0x0403_4b50 else {
            throw ArchiveError.damaged("no local header for \(entry.name)")
        }
        try handle.seek(toOffset: entry.offset + 30 + UInt64(header.le16(26)) + UInt64(header.le16(28)))
        var crc = CRC32()
        var produced: UInt64 = 0
        func emit(_ data: Data) throws {
            produced += UInt64(data.count)
            guard produced <= entry.size else { throw ArchiveError.damaged("\(entry.name) is longer than its size") }
            crc.update(data)
            try chunk(data)
        }
        if entry.method == 0 {
            var remaining = entry.compressedSize
            while remaining > 0 {
                try Work.check(stop)
                guard let data = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !data.isEmpty else {
                    throw ArchiveError.damaged("\(entry.name) is cut short")
                }
                remaining -= UInt64(data.count)
                try emit(data)
            }
        } else {
            try inflate(handle, compressedSize: entry.compressedSize, name: entry.name, stop: stop, emit)
        }
        guard produced == entry.size, crc.value == entry.crc32 else { throw ArchiveError.damaged("\(entry.name) fails its CRC check") }
    }

    /// Raw DEFLATE (zip's method 8), what COMPRESSION_ZLIB decodes, a chunk at a time.
    private static func inflate(_ handle: FileHandle, compressedSize: UInt64, name: String, stop: Shell.CancelFlag,
                                _ emit: (Data) throws -> Void) throws {
        let cut = ArchiveError.damaged("\(name) is cut short")
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw cut }
        defer { compression_stream_destroy(stream) }
        let size = 1 << 20
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { output.deallocate() }
        var remaining = compressedSize
        while true {
            try Work.check(stop)
            var input = Data([0])
            var count = 0
            if remaining > 0 {
                guard let data = try handle.read(upToCount: Int(min(remaining, UInt64(size)))), !data.isEmpty else { throw cut }
                remaining -= UInt64(data.count)
                input = data
                count = data.count
            }
            let last = remaining == 0
            let ended: Bool = try input.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw cut }
                stream.pointee.src_ptr = base
                stream.pointee.src_size = count
                while true {
                    try Work.check(stop)
                    stream.pointee.dst_ptr = output
                    stream.pointee.dst_size = size
                    let status = compression_stream_process(stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    if status == COMPRESSION_STATUS_ERROR { throw ArchiveError.damaged("\(name) can't be inflated") }
                    let made = size - stream.pointee.dst_size
                    if made > 0 { try emit(Data(bytes: output, count: made)) }
                    if status == COMPRESSION_STATUS_END { return true }
                    if stream.pointee.src_size == 0, made < size {
                        if !last { return false }
                        if made == 0 { throw cut }
                    }
                }
            }
            if ended { return }
        }
    }

    /// Other methods (deflate64, bzip2, an encrypted entry): unzip writes it to a temporary file, read back in chunks.
    private static func streamWithUnzip(_ entry: Entry, in zip: URL, stop: Shell.CancelFlag, _ chunk: (Data) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "ArchiveKit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try Tool.run("/usr/bin/unzip", ["-p", zip.path, unzipPattern(entry.name)],
                                  Shell.Options(stdout: .file(temporary), stderr: .capture), stop: stop)
        guard output.succeeded else { throw ArchiveError.toolFailed(failure(output)) }
        try streamFile(temporary, stop: stop, chunk)
    }

    /// A file's bytes in chunks of at most 1 MB.
    static func streamFile(_ file: URL, stop: Shell.CancelFlag, _ chunk: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            try Work.check(stop)
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { return }
            try chunk(data)
        }
    }

    /// Writes a stream of chunks to a new file.
    static func write(to file: URL, _ produce: ((Data) throws -> Void) throws -> Void) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path]) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try produce { try handle.write(contentsOf: $0) }
    }

    /// Lowercase hex, as shasum and md5 print it.
    static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The CRC-32 zip stores for every entry.
struct CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var crc = state
        Self.table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { bytes in
                for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            }
        }
        state = crc
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }
}
