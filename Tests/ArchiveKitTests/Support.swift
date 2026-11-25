import Foundation
import ArchiveKit
import ProcessKit

/// A new empty folder under the temporary directory, removed by the caller's `defer`.
func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ArchiveKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    guard let real = realpath(url.path, nil) else { return url }
    let path = String(cString: real)
    free(real)
    return URL(fileURLWithPath: path, isDirectory: true)
}

func writeText(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// A zip's file names, without folders and the __MACOSX entries ditto adds for macOS metadata.
func fileNames(_ zip: URL) throws -> Set<String> {
    Set(try ArchiveKit.Zip.entries(zip).filter { !$0.isMacMetadata && !$0.isDirectory }.map(\.name))
}

func readText(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

/// Everything in a folder, hidden files included, as relative paths.
func contents(_ folder: URL) -> [String] {
    ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

/// Writes zips by hand, stored entries only, so tests can make the ones no tool would: "../" names,
/// absolute paths, symbolic links pointing out, wrong checksums, ZIP64 records.
struct ZipMaker {
    struct Item {
        var name: String
        var data: Data
        /// Unix mode with its type: 0o100644 a file, 0o120777 a symbolic link (data is its target), 0o040755 a folder.
        var mode: UInt32 = 0o100644
        var badCRC = false
    }

    var items: [Item] = []

    mutating func file(_ name: String, _ text: String) { items.append(Item(name: name, data: Data(text.utf8))) }
    mutating func folder(_ name: String) { items.append(Item(name: name, data: Data(), mode: 0o040755)) }
    mutating func link(_ name: String, to target: String) { items.append(Item(name: name, data: Data(target.utf8), mode: 0o120777)) }

    func write(to url: URL, zip64: Bool = false) throws {
        var body = Data()
        var central = Data()
        for item in items {
            let name = Data(item.name.utf8)
            let crc = item.badCRC ? 0xDEAD_BEEF : Self.crc32(item.data)
            let offset = UInt32(body.count)
            body.le32(0x0403_4b50); body.le16(20); body.le16(0x0800); body.le16(0); body.le16(0); body.le16(0x21)
            body.le32(crc); body.le32(UInt32(item.data.count)); body.le32(UInt32(item.data.count))
            body.le16(UInt16(name.count)); body.le16(0); body.append(name); body.append(item.data)
            central.le32(0x0201_4b50); central.le16(0x0314); central.le16(20); central.le16(0x0800); central.le16(0)
            central.le16(0); central.le16(0x21); central.le32(crc)
            central.le32(UInt32(item.data.count)); central.le32(UInt32(item.data.count))
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(item.mode << 16); central.le32(offset); central.append(name)
        }
        var end = Data()
        let count = UInt16(items.count)
        if zip64 {
            let recordOffset = UInt64(body.count + central.count)
            end.le32(0x0606_4b50); end.le64(44); end.le16(45); end.le16(45); end.le32(0); end.le32(0)
            end.le64(UInt64(items.count)); end.le64(UInt64(items.count)); end.le64(UInt64(central.count)); end.le64(UInt64(body.count))
            end.le32(0x0706_4b50); end.le32(0); end.le64(recordOffset); end.le32(1)
            end.le32(0x0605_4b50); end.le16(0); end.le16(0); end.le16(0xFFFF); end.le16(0xFFFF)
            end.le32(0xFFFF_FFFF); end.le32(0xFFFF_FFFF); end.le16(0)
        } else {
            end.le32(0x0605_4b50); end.le16(0); end.le16(0); end.le16(count); end.le16(count)
            end.le32(UInt32(central.count)); end.le32(UInt32(body.count)); end.le16(0)
        }
        try (body + central + end).write(to: url)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le64(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

/// A zip made by Info-ZIP's zip, the way other tools make them.
func infoZip(_ items: [String], in folder: URL, to zip: URL) async throws {
    try await Shell.run("/usr/bin/zip", ["-qry", zip.path] + items, in: folder).check()
}
