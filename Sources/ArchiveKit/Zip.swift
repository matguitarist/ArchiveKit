import Foundation
import ProcessKit

/// Zip files, safely. Entries are read from the zip's own directory, every one is checked before
/// anything is written (Zip Slip: absolute paths, "..", drive letters, symbolic links pointing out),
/// and unpacking and packing happen beside the target, moved into place only when whole.
/// Unpacking and packing use ditto, like the Finder, so names, permissions and macOS metadata survive.
public enum Zip {
    // MARK: Reading the directory

    /// Whether the file starts like a zip (PK\3\4, or PK\5\6 for an empty one).
    public static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        return head[0] == 0x50 && head[1] == 0x4B && [0x03, 0x05, 0x07].contains(head[2])
    }

    /// Every entry, from the zip's central directory (ZIP64 too). Reads only the directory.
    public static func entries(_ zip: URL) throws(ArchiveError) -> [Entry] {
        guard isZip(zip) else {
            let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            throw .notAZip(size: Int64(size))
        }
        return try readDirectory(zip)
    }

    /// The names inside the zip, folders included ("Game/").
    public static func names(_ zip: URL) throws(ArchiveError) -> [String] {
        try entries(zip).map(\.name)
    }

    /// The total uncompressed size, to show before unpacking.
    public static func uncompressedSize(_ zip: URL) throws(ArchiveError) -> UInt64 {
        try entries(zip).reduce(0) { $0 + $1.size }
    }

    /// The first entry that would land outside the folder it's unpacked into, or nil when all are safe:
    /// a bad name, a symbolic link pointing out, or an entry inside a symbolic link.
    public static func unsafeEntry(_ entries: [Entry]) -> String? {
        Safety.firstUnsafe(entries)
    }

    /// The same check on names alone (from another tool's listing): absolute, drive letter, or "..".
    public static func unsafeEntry(_ names: [String]) -> String? {
        names.first(where: Safety.isUnsafe)
    }

    /// The names at the top of the zip ("Saves", "config.ini"), macOS metadata left out.
    public static func topLevelNames(_ entries: [Entry]) -> [String] {
        var seen: [String] = []
        for entry in entries where !entry.isMacMetadata {
            if let first = Safety.parts(entry.name).first, !seen.contains(first) { seen.append(first) }
        }
        return seen
    }

    // MARK: Unpacking

    /// Unpacks `zip` into `folder`. Every entry is checked first; then it unpacks into a hidden folder
    /// beside `folder` and moves it into place when whole, so a failure, a refusal or a cancel leaves
    /// nothing half-written. Returns `folder`.
    /// - Parameters:
    ///   - replacing: false throws `.exists` when `folder` is there; true swaps it out, and what was
    ///     there goes to `replaced` once the new one is in place.
    ///   - dropsQuarantine: true leaves the downloaded-file mark off what comes out (a game's executables).
    ///   - maxBytes, maxEntries: refuse a zip bigger than this, before anything is written.
    @discardableResult
    public static func unpack(
        _ zip: URL, into folder: URL, replacing: Bool = false, replaced: Disposal = .trash,
        dropsQuarantine: Bool = false, maxBytes: UInt64? = nil, maxEntries: Int? = nil
    ) async throws -> URL {
        let entries = try entries(zip)
        if let bad = unsafeEntry(entries) { throw ArchiveError.unsafeEntry(bad) }
        if let maxEntries, entries.count > maxEntries { throw ArchiveError.tooLarge }
        if let maxBytes, entries.reduce(0, { $0 + $1.size }) > maxBytes { throw ArchiveError.tooLarge }
        if !replacing, FileManager.default.fileExists(atPath: folder.path) { throw ArchiveError.exists(folder) }

        let staging = try Staging.folder(beside: folder, purpose: "unpacking")
        do {
            let output = try await Shell.run("/usr/bin/ditto", ["-x", "-k"] + (dropsQuarantine ? ["--noqtn"] : []) + [zip.path, staging.path],
                                             options: Shell.Options(stdout: .discard))
            guard output.succeeded else { throw ArchiveError.toolFailed(failure(output)) }
            if let bad = Safety.escapingLink(in: staging) { throw ArchiveError.unsafeEntry(bad) }
            try Staging.swap(staging, into: folder, dispose: replaced.callAsFunction)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return folder
    }

    /// The folder that holds an unpacked zip's content: its only folder when it holds one folder and
    /// nothing else (a zipped folder), else itself. Hidden files and __MACOSX don't count.
    public static func contentFolder(_ folder: URL) -> URL {
        let items = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return items[0] }
        return folder
    }

    // MARK: Reading one entry

    /// One entry's bytes, read into memory. Throws `.tooLarge` past `limit` bytes, `.missingEntry` when
    /// there is no such entry.
    public static func read(_ entry: String, from zip: URL, limit: Int) async throws -> Data {
        guard let found = try entries(zip).first(where: { $0.name == entry }) else { throw ArchiveError.missingEntry(entry) }
        if found.size > UInt64(limit) { throw ArchiveError.tooLarge }
        let output = try await Shell.run("/usr/bin/unzip", ["-p", zip.path, unzipPattern(entry)],
                                         options: Shell.Options(stderr: .capture, outputLimit: limit))
        if output.truncated { throw ArchiveError.tooLarge }
        guard output.succeeded else { throw ArchiveError.toolFailed(failure(output)) }
        return output.stdout
    }

    /// Writes one entry to `file` (replaced when there), streaming: nothing is held in memory.
    public static func extract(_ entry: String, from zip: URL, to file: URL) async throws {
        guard try entries(zip).contains(where: { $0.name == entry && !$0.isDirectory }) else { throw ArchiveError.missingEntry(entry) }
        let partial = try Staging.file(beside: file, purpose: "partial")
        do {
            let output = try await Shell.run("/usr/bin/unzip", ["-p", zip.path, unzipPattern(entry)],
                                             options: Shell.Options(stdout: .file(partial)))
            guard output.succeeded else { throw ArchiveError.toolFailed(failure(output)) }
            try Staging.swap(partial, into: file, dispose: Disposal.delete.callAsFunction)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Checks every entry's data against its CRC (unzip -t). Throws `.toolFailed` when one is damaged.
    public static func test(_ zip: URL) async throws {
        let output = try await Shell.run("/usr/bin/unzip", ["-tqq", zip.path])
        guard output.succeeded else { throw ArchiveError.toolFailed(failure(output)) }
    }

    // MARK: Packing

    /// Zips `source` into `zip`, written beside it first and moved into place when whole.
    /// - Parameters:
    ///   - items: names inside `source` to put at the top of the zip; nil for all of it.
    ///   - keepParent: the folder itself as the zip's top entry (like the Finder's Compress); false puts
    ///     its content at the top. A file is always at the top.
    ///   - macMetadata: true keeps resource forks, extended attributes and ACLs (ditto --sequesterRsrc);
    ///     false makes a plain zip every tool reads the same.
    ///   - level: zlib compression level, 0 to 9; nil for ditto's default.
    ///   - replacing: false throws `.exists` when `zip` is there.
    @discardableResult
    public static func pack(
        _ source: URL, to zip: URL, items: [String]? = nil, keepParent: Bool = false,
        macMetadata: Bool = true, level: Int? = nil, replacing: Bool = false, replaced: Disposal = .delete
    ) async throws -> URL {
        let files = FileManager.default
        if !replacing, files.fileExists(atPath: zip.path) { throw ArchiveError.exists(zip) }
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: source.path, isDirectory: &isFolder) else { throw ArchiveError.nothingToBackUp }

        var options = ["-c", "-k"] + (macMetadata ? ["--sequesterRsrc"] : ["--norsrc", "--noextattr", "--noacl"])
        if let level { options += ["--zlibCompressionLevel", String(min(max(level, 0), 9))] }
        var cleanup: URL?
        var input = source
        if let items {
            // ditto zips one folder: the items go in one, as clones on APFS.
            let present = items.filter { !Safety.isUnsafe($0) && files.fileExists(atPath: source.appending(path: $0).path) }
            guard !present.isEmpty else { throw ArchiveError.nothingToBackUp }
            let gathered = try Staging.folder(beside: zip, purpose: "gathering")
            cleanup = gathered
            do {
                for item in present { try files.copyItem(at: source.appending(path: item), to: gathered.appending(path: item)) }
            } catch {
                try? files.removeItem(at: gathered)
                throw error
            }
            input = gathered
        } else if keepParent, isFolder.boolValue {
            options.append("--keepParent")
        }
        defer { if let cleanup { try? files.removeItem(at: cleanup) } }

        let partial = try Staging.file(beside: zip, purpose: "partial")
        do {
            let output = try await Shell.run("/usr/bin/ditto", options + [input.path, partial.path], options: Shell.Options(stdout: .discard))
            guard output.succeeded else { throw ArchiveError.toolFailed(failure(output)) }
            try Staging.swap(partial, into: zip, dispose: replaced.callAsFunction)
        } catch {
            try? files.removeItem(at: partial)
            throw error
        }
        return zip
    }

    // MARK: Helpers

    /// unzip reads [ ] * ? in a name as a pattern: escaped, the exact entry is read.
    static func unzipPattern(_ name: String) -> String {
        var pattern = ""
        for character in name {
            switch character {
            case "[": pattern += "[[]"
            case "*": pattern += "[*]"
            case "?": pattern += "[?]"
            default: pattern.append(character)
            }
        }
        return pattern
    }

    static func failure(_ output: Shell.Output) -> String {
        output.message.isEmpty ? "\(output.name) failed (exit status \(output.status))." : output.message
    }
}
