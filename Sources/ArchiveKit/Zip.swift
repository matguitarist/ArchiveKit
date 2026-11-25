import CryptoKit
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
    ///   - cancel: stops it from code that has no task to cancel (a stop button's flag); it then throws
    ///     `CancellationError` and leaves nothing behind. Cancelling the task does the same.
    @discardableResult
    public static func unpack(
        _ zip: URL, into folder: URL, replacing: Bool = false, replaced: Disposal = .trash,
        dropsQuarantine: Bool = false, maxBytes: UInt64? = nil, maxEntries: Int? = nil, cancel: Shell.CancelFlag? = nil
    ) async throws -> URL {
        try await Work.run(cancel) { stop in
            try unpack(zip, folder, replacing, replaced, dropsQuarantine, maxBytes, maxEntries, stop)
        }
    }

    /// `unpack` on the calling thread, for code that isn't async. Never on the main thread.
    @discardableResult
    public static func unpackSync(
        _ zip: URL, into folder: URL, replacing: Bool = false, replaced: Disposal = .trash,
        dropsQuarantine: Bool = false, maxBytes: UInt64? = nil, maxEntries: Int? = nil, cancel: Shell.CancelFlag? = nil
    ) throws -> URL {
        try unpack(zip, folder, replacing, replaced, dropsQuarantine, maxBytes, maxEntries, cancel ?? Shell.CancelFlag())
    }

    private static func unpack(_ zip: URL, _ folder: URL, _ replacing: Bool, _ replaced: Disposal, _ dropsQuarantine: Bool,
                               _ maxBytes: UInt64?, _ maxEntries: Int?, _ stop: Shell.CancelFlag) throws -> URL {
        let entries = try entries(zip)
        if let bad = unsafeEntry(entries) { throw ArchiveError.unsafeEntry(bad) }
        if let maxEntries, entries.count > maxEntries { throw ArchiveError.tooLarge }
        if let maxBytes, entries.reduce(0, { $0 + $1.size }) > maxBytes { throw ArchiveError.tooLarge }
        if !replacing, FileManager.default.fileExists(atPath: folder.path) { throw ArchiveError.exists(folder) }

        let staging = try Staging.folder(beside: folder, purpose: "unpacking")
        do {
            let output = try Tool.run("/usr/bin/ditto", ["-x", "-k"] + (dropsQuarantine ? ["--noqtn"] : []) + [zip.path, staging.path],
                                      Shell.Options(stdout: .discard), stop: stop)
            guard output.succeeded else { throw ArchiveError.toolFailed(failure(output)) }
            if let bad = Safety.escapingLink(in: staging) { throw ArchiveError.unsafeEntry(bad) }
            try Work.check(stop)
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
    /// there is no such file, `.damaged` when its bytes don't match its CRC.
    public static func read(_ entry: String, from zip: URL, limit: Int, cancel: Shell.CancelFlag? = nil) async throws -> Data {
        try await Work.run(cancel) { stop in try read(entry, zip, limit, stop) }
    }

    /// `read` on the calling thread (a game starting, a scan that isn't async).
    public static func readSync(_ entry: String, from zip: URL, limit: Int, cancel: Shell.CancelFlag? = nil) throws -> Data {
        try read(entry, zip, limit, cancel ?? Shell.CancelFlag())
    }

    private static func read(_ name: String, _ zip: URL, _ limit: Int, _ stop: Shell.CancelFlag) throws -> Data {
        let found = try entry(named: name, in: zip)
        if found.size > UInt64(limit) { throw ArchiveError.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(found.size))
        try stream(found, in: zip, stop: stop) { chunk in
            guard data.count + chunk.count <= limit else { throw ArchiveError.tooLarge }
            data.append(chunk)
        }
        return data
    }

    /// Hands one entry's bytes to `chunk`, 1 MB at most at a time, on the calling thread: a 4 GB disc image
    /// is never held in memory nor written anywhere. Checked against the entry's CRC at the end (`.damaged`).
    public static func stream(_ entry: String, from zip: URL, cancel: Shell.CancelFlag? = nil, chunk: (Data) throws -> Void) throws {
        try stream(Zip.entry(named: entry, in: zip), in: zip, stop: cancel ?? Shell.CancelFlag(), chunk)
    }

    /// One entry's hash, streamed: `Insecure.MD5.self`, `SHA256.self`… Lowercase hex.
    public static func hash<H: HashFunction>(_ entry: String, from zip: URL, using function: H.Type, cancel: Shell.CancelFlag? = nil) async throws -> String {
        try await Work.run(cancel) { stop in try hash(entry, zip, H.self, stop) }
    }

    /// `hash` on the calling thread.
    public static func hashSync<H: HashFunction>(_ entry: String, from zip: URL, using function: H.Type, cancel: Shell.CancelFlag? = nil) throws -> String {
        try hash(entry, zip, H.self, cancel ?? Shell.CancelFlag())
    }

    private static func hash<H: HashFunction>(_ name: String, _ zip: URL, _ function: H.Type, _ stop: Shell.CancelFlag) throws -> String {
        var hasher = H()
        try stream(entry(named: name, in: zip), in: zip, stop: stop) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    /// Writes one entry to `file` (replaced when there), streaming: nothing is held in memory.
    public static func extract(_ entry: String, from zip: URL, to file: URL, cancel: Shell.CancelFlag? = nil) async throws {
        try await Work.run(cancel) { stop in try extract([entry: file], zip, stop) }
    }

    /// `extract` on the calling thread.
    public static func extractSync(_ entry: String, from zip: URL, to file: URL, cancel: Shell.CancelFlag? = nil) throws {
        try extract([entry: file], zip, cancel ?? Shell.CancelFlag())
    }

    /// Writes several entries, each to its file (`["AM2R_11/data.win": work/data.win, …]`), reading the
    /// directory once. Nothing is replaced until every one is written whole.
    public static func extract(_ entries: [String: URL], from zip: URL, cancel: Shell.CancelFlag? = nil) async throws {
        try await Work.run(cancel) { stop in try extract(entries, zip, stop) }
    }

    /// The same on the calling thread.
    public static func extractSync(_ entries: [String: URL], from zip: URL, cancel: Shell.CancelFlag? = nil) throws {
        try extract(entries, zip, cancel ?? Shell.CancelFlag())
    }

    private static func extract(_ wanted: [String: URL], _ zip: URL, _ stop: Shell.CancelFlag) throws {
        let all = try entries(zip)
        var partials: [(partial: URL, file: URL)] = []
        do {
            for (name, file) in wanted.sorted(by: { $0.key < $1.key }) {
                guard let found = all.first(where: { $0.name == name && !$0.isDirectory }) else { throw ArchiveError.missingEntry(name) }
                let partial = try Staging.file(beside: file, purpose: "partial")
                partials.append((partial, file))
                try write(to: partial) { sink in try stream(found, in: zip, stop: stop, sink) }
            }
            try Work.check(stop)
            for item in partials { try Staging.swap(item.partial, into: item.file, dispose: Disposal.delete.callAsFunction) }
        } catch {
            for item in partials { try? FileManager.default.removeItem(at: item.partial) }
            throw error
        }
    }

    /// Checks every entry's data against its CRC (unzip -t). Throws `.toolFailed` when one is damaged.
    public static func test(_ zip: URL, cancel: Shell.CancelFlag? = nil) async throws {
        try await Work.run(cancel) { stop in try test(zip, stop) }
    }

    /// `test` on the calling thread.
    public static func testSync(_ zip: URL, cancel: Shell.CancelFlag? = nil) throws {
        try test(zip, cancel ?? Shell.CancelFlag())
    }

    private static func test(_ zip: URL, _ stop: Shell.CancelFlag) throws {
        let output = try Tool.run("/usr/bin/unzip", ["-tqq", zip.path], stop: stop)
        guard output.succeeded else { throw ArchiveError.toolFailed(failure(output)) }
    }

    // MARK: Packing

    /// Zips `source` into `zip`, written beside it first and moved into place when whole.
    /// - Parameters:
    ///   - items: names inside `source` to put in the zip, at the same path ("Saves/Slot 1" keeps its
    ///     "Saves" folder); nil for all of it. Names that aren't there are skipped.
    ///   - keepParent: the folder itself as the zip's top entry (like the Finder's Compress); false puts
    ///     its content at the top. A file is always at the top.
    ///   - macMetadata: true keeps resource forks, extended attributes and ACLs (ditto --sequesterRsrc);
    ///     false makes a plain zip every tool reads the same.
    ///   - level: zlib compression level, 0 to 9; nil for ditto's default.
    ///   - replacing: false throws `.exists` when `zip` is there; true puts what was there to `replaced`.
    ///   - folderEntries: false leaves out the entries for folders (zip -D), as arcade romsets want.
    ///   - dropsDSStore: true leaves out the Finder's .DS_Store files.
    ///   - cancel: stops it from code that has no task to cancel; nothing is left behind.
    @discardableResult
    public static func pack(
        _ source: URL, to zip: URL, items: [String]? = nil, keepParent: Bool = false,
        macMetadata: Bool = true, level: Int? = nil, replacing: Bool = false, replaced: Disposal = .delete,
        folderEntries: Bool = true, dropsDSStore: Bool = false, cancel: Shell.CancelFlag? = nil
    ) async throws -> URL {
        let options = PackOptions(macMetadata: macMetadata, level: level, replacing: replacing, replaced: replaced,
                                  folderEntries: folderEntries, dropsDSStore: dropsDSStore)
        return try await Work.run(cancel) { stop in try pack(source, zip, items, keepParent, options, stop) }
    }

    /// `pack` on the calling thread.
    @discardableResult
    public static func packSync(
        _ source: URL, to zip: URL, items: [String]? = nil, keepParent: Bool = false,
        macMetadata: Bool = true, level: Int? = nil, replacing: Bool = false, replaced: Disposal = .delete,
        folderEntries: Bool = true, dropsDSStore: Bool = false, cancel: Shell.CancelFlag? = nil
    ) throws -> URL {
        let options = PackOptions(macMetadata: macMetadata, level: level, replacing: replacing, replaced: replaced,
                                  folderEntries: folderEntries, dropsDSStore: dropsDSStore)
        return try pack(source, zip, items, keepParent, options, cancel ?? Shell.CancelFlag())
    }

    /// Zips files from anywhere side by side at the top of the zip, like `zip -j` (a problem report: logs,
    /// settings, about.txt). Two with the same name become "name" and "name 2". Missing files are skipped.
    @discardableResult
    public static func pack(
        files: [URL], to zip: URL, macMetadata: Bool = false, level: Int? = nil, replacing: Bool = false,
        replaced: Disposal = .delete, cancel: Shell.CancelFlag? = nil
    ) async throws -> URL {
        let entries = topLevel(files)
        return try await pack(entries: entries, to: zip, macMetadata: macMetadata, level: level, replacing: replacing,
                              replaced: replaced, folderEntries: false, cancel: cancel)
    }

    /// `pack(files:)` on the calling thread.
    @discardableResult
    public static func packSync(
        files: [URL], to zip: URL, macMetadata: Bool = false, level: Int? = nil, replacing: Bool = false,
        replaced: Disposal = .delete, cancel: Shell.CancelFlag? = nil
    ) throws -> URL {
        try packSync(entries: topLevel(files), to: zip, macMetadata: macMetadata, level: level, replacing: replacing,
                     replaced: replaced, folderEntries: false, cancel: cancel)
    }

    /// Zips files and folders from anywhere under the names given: `["about.txt": about,
    /// "roms/mslug.bin": part]`. Names are checked like an unpacked zip's ("..", absolute paths refused
    /// with `.unsafeEntry`). Missing sources are skipped; `.nothingToBackUp` when none is there.
    @discardableResult
    public static func pack(
        entries: [String: URL], to zip: URL, macMetadata: Bool = false, level: Int? = nil, replacing: Bool = false,
        replaced: Disposal = .delete, folderEntries: Bool = true, dropsDSStore: Bool = false, cancel: Shell.CancelFlag? = nil
    ) async throws -> URL {
        let options = PackOptions(macMetadata: macMetadata, level: level, replacing: replacing, replaced: replaced,
                                  folderEntries: folderEntries, dropsDSStore: dropsDSStore)
        return try await Work.run(cancel) { stop in try pack(entries, zip, options, stop) }
    }

    /// `pack(entries:)` on the calling thread.
    @discardableResult
    public static func packSync(
        entries: [String: URL], to zip: URL, macMetadata: Bool = false, level: Int? = nil, replacing: Bool = false,
        replaced: Disposal = .delete, folderEntries: Bool = true, dropsDSStore: Bool = false, cancel: Shell.CancelFlag? = nil
    ) throws -> URL {
        let options = PackOptions(macMetadata: macMetadata, level: level, replacing: replacing, replaced: replaced,
                                  folderEntries: folderEntries, dropsDSStore: dropsDSStore)
        return try pack(entries, zip, options, cancel ?? Shell.CancelFlag())
    }

    struct PackOptions: Sendable {
        var macMetadata: Bool
        var level: Int?
        var replacing: Bool
        var replaced: Disposal
        var folderEntries: Bool
        var dropsDSStore: Bool
    }

    /// Each file under its own name, "name 2" for a second one.
    private static func topLevel(_ files: [URL]) -> [String: URL] {
        var entries: [String: URL] = [:]
        for file in files {
            let (stem, ext) = UniqueName.split(file.lastPathComponent)
            var name = file.lastPathComponent
            var number = 2
            while entries[name] != nil {
                name = "\(stem) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
                number += 1
            }
            entries[name] = file
        }
        return entries
    }

    private static func pack(_ source: URL, _ zip: URL, _ items: [String]?, _ keepParent: Bool, _ options: PackOptions,
                             _ stop: Shell.CancelFlag) throws -> URL {
        let files = FileManager.default
        if !options.replacing, files.fileExists(atPath: zip.path) { throw ArchiveError.exists(zip) }
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: source.path, isDirectory: &isFolder) else { throw ArchiveError.nothingToBackUp }
        guard let items else {
            return try write(source, keepParent: keepParent && isFolder.boolValue, to: zip, options, stop)
        }
        // ditto zips one folder: the items go in one, as clones on APFS.
        let present = items.filter { !Safety.isUnsafe($0) && files.fileExists(atPath: source.appending(path: $0).path) }
        guard !present.isEmpty else { throw ArchiveError.nothingToBackUp }
        return try gathered(present.map { ($0, source.appending(path: $0)) }, beside: zip, stop) { folder in
            try write(folder, keepParent: false, to: zip, options, stop)
        }
    }

    private static func pack(_ entries: [String: URL], _ zip: URL, _ options: PackOptions, _ stop: Shell.CancelFlag) throws -> URL {
        let files = FileManager.default
        if !options.replacing, files.fileExists(atPath: zip.path) { throw ArchiveError.exists(zip) }
        if let bad = entries.keys.sorted().first(where: Safety.isUnsafe) { throw ArchiveError.unsafeEntry(bad) }
        let present = entries.sorted { $0.key < $1.key }.filter { files.fileExists(atPath: $0.value.path) }
        guard !present.isEmpty else { throw ArchiveError.nothingToBackUp }
        return try gathered(present.map { ($0.key, $0.value) }, beside: zip, stop) { folder in
            try write(folder, keepParent: false, to: zip, options, stop)
        }
    }

    /// Copies (clones on APFS) each source to its name in a hidden folder beside `zip`, runs `body` on it,
    /// then removes it.
    private static func gathered(_ items: [(name: String, source: URL)], beside zip: URL, _ stop: Shell.CancelFlag,
                                 _ body: (URL) throws -> URL) throws -> URL {
        let files = FileManager.default
        let folder = try Staging.folder(beside: zip, purpose: "gathering")
        defer { try? files.removeItem(at: folder) }
        for item in items {
            try Work.check(stop)
            let target = folder.appending(path: item.name)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: item.source, to: target)
        }
        return try body(folder)
    }

    /// ditto writes the zip beside `zip`; folder entries and .DS_Store come out after when asked; then it
    /// moves into place.
    private static func write(_ input: URL, keepParent: Bool, to zip: URL, _ options: PackOptions, _ stop: Shell.CancelFlag) throws -> URL {
        var arguments = ["-c", "-k"] + (options.macMetadata ? ["--sequesterRsrc"] : ["--norsrc", "--noextattr", "--noacl"])
        if let level = options.level { arguments += ["--zlibCompressionLevel", String(min(max(level, 0), 9))] }
        if keepParent { arguments.append("--keepParent") }
        let partial = try Staging.file(beside: zip, purpose: "partial")
        do {
            let output = try Tool.run("/usr/bin/ditto", arguments + [input.path, partial.path], Shell.Options(stdout: .discard), stop: stop)
            guard output.succeeded else { throw ArchiveError.toolFailed(failure(output)) }
            var patterns: [String] = []
            if !options.folderEntries { patterns.append("*/") }
            if options.dropsDSStore { patterns.append("*.DS_Store") }
            if !patterns.isEmpty { try remove(patterns, from: partial, stop) }
            try Work.check(stop)
            try Staging.swap(partial, into: zip, dispose: options.replaced.callAsFunction)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return zip
    }

    /// zip -d: the entries matching `patterns` come out. Its temporary file goes in a hidden folder.
    private static func remove(_ patterns: [String], from zip: URL, _ stop: Shell.CancelFlag) throws {
        let temporary = try Staging.folder(beside: zip, purpose: "temp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try Tool.run("/usr/bin/zip", ["-q", "-b", temporary.path, "-d", zip.path] + patterns, Shell.Options(stdout: .discard), stop: stop)
        // 12: nothing matched, nothing to do.
        guard output.succeeded || output.status == 12 else { throw ArchiveError.toolFailed(failure(output)) }
        // zip removes a zip left empty.
        guard FileManager.default.fileExists(atPath: zip.path) else { throw ArchiveError.nothingToBackUp }
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
        guard output.message.isEmpty else { return output.message }
        return ArchiveError.isFrench(ArchiveError.appLanguage)
            ? "\(output.name) a échoué (code de sortie \(output.status))."
            : "\(output.name) failed (exit status \(output.status))."
    }
}
