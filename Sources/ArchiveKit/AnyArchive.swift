import CryptoKit
import Foundation
import ProcessKit

/// Any archive macOS's tar (bsdtar, libarchive) reads: 7z, RAR, tar, tar.gz, tar.bz2, xz, and zip too.
/// No third-party tool. Names are checked before anything is written, and unpacking happens beside
/// the target, moved into place when whole, then checked again for links pointing out.
/// Every call has a `Sync` twin for code that isn't async, and takes a `cancel` flag.
public enum AnyArchive {
    /// The extensions worth trying: zip goes through `Zip` for its macOS metadata.
    public static let extensions: Set<String> = ["7z", "rar", "tar", "tgz", "gz", "bz2", "tbz", "tbz2", "xz", "txz", "zip"]

    // MARK: Listing

    /// The names inside, as tar lists them (folders end with "/").
    public static func names(_ archive: URL, cancel: Shell.CancelFlag? = nil) async throws -> [String] {
        try await Work.run(cancel) { stop in try names(archive, stop) }
    }

    /// `names` on the calling thread.
    public static func namesSync(_ archive: URL, cancel: Shell.CancelFlag? = nil) throws -> [String] {
        try names(archive, cancel ?? Shell.CancelFlag())
    }

    private static func names(_ archive: URL, _ stop: Shell.CancelFlag) throws -> [String] {
        let output = try Tool.run("/usr/bin/tar", ["-tf", archive.path], stop: stop)
        guard output.succeeded else { throw ArchiveError.toolFailed(Zip.failure(output)) }
        return output.lines.filter { !$0.isEmpty }
    }

    // MARK: Reading entries

    /// One entry's bytes, read into memory; `.tooLarge` past `limit` bytes.
    public static func read(_ entry: String, from archive: URL, limit: Int, cancel: Shell.CancelFlag? = nil) async throws -> Data {
        try await Work.run(cancel) { stop in try read(entry, archive, limit, stop) }
    }

    /// `read` on the calling thread.
    public static func readSync(_ entry: String, from archive: URL, limit: Int, cancel: Shell.CancelFlag? = nil) throws -> Data {
        try read(entry, archive, limit, cancel ?? Shell.CancelFlag())
    }

    private static func read(_ entry: String, _ archive: URL, _ limit: Int, _ stop: Shell.CancelFlag) throws -> Data {
        guard try names(archive, stop).contains(entry) else { throw ArchiveError.missingEntry(entry) }
        let output = try Tool.run("/usr/bin/tar", ["-xOf", archive.path, "--", tarPattern(entry)],
                                  Shell.Options(outputLimit: limit), stop: stop)
        if output.truncated { throw ArchiveError.tooLarge }
        guard output.succeeded else { throw ArchiveError.toolFailed(Zip.failure(output)) }
        return output.stdout
    }

    /// Hands one entry's bytes to `chunk`, 1 MB at most at a time, on the calling thread. tar writes it to a
    /// temporary file first (a 7z can't be read in place), removed at the end; nothing large is held in memory.
    public static func stream(_ entry: String, from archive: URL, cancel: Shell.CancelFlag? = nil, chunk: (Data) throws -> Void) throws {
        try stream(entry, archive, cancel ?? Shell.CancelFlag(), chunk)
    }

    private static func stream(_ entry: String, _ archive: URL, _ stop: Shell.CancelFlag, _ chunk: (Data) throws -> Void) throws {
        guard try names(archive, stop).contains(entry) else { throw ArchiveError.missingEntry(entry) }
        let temporary = FileManager.default.temporaryDirectory.appending(path: "ArchiveKit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try Tool.run("/usr/bin/tar", ["-xOf", archive.path, "--", tarPattern(entry)],
                                  Shell.Options(stdout: .file(temporary)), stop: stop)
        guard output.succeeded else { throw ArchiveError.toolFailed(Zip.failure(output)) }
        try Zip.streamFile(temporary, stop: stop, chunk)
    }

    /// One entry's hash (`Insecure.MD5.self`, `SHA256.self`…), lowercase hex.
    public static func hash<H: HashFunction>(_ entry: String, from archive: URL, using function: H.Type, cancel: Shell.CancelFlag? = nil) async throws -> String {
        try await Work.run(cancel) { stop in try hash(entry, archive, H.self, stop) }
    }

    /// `hash` on the calling thread.
    public static func hashSync<H: HashFunction>(_ entry: String, from archive: URL, using function: H.Type, cancel: Shell.CancelFlag? = nil) throws -> String {
        try hash(entry, archive, H.self, cancel ?? Shell.CancelFlag())
    }

    private static func hash<H: HashFunction>(_ entry: String, _ archive: URL, _ function: H.Type, _ stop: Shell.CancelFlag) throws -> String {
        var hasher = H()
        try stream(entry, archive, stop) { hasher.update(data: $0) }
        return Zip.hex(hasher.finalize())
    }

    /// Writes one entry to `file` (replaced when there), streaming.
    public static func extract(_ entry: String, from archive: URL, to file: URL, cancel: Shell.CancelFlag? = nil) async throws {
        try await Work.run(cancel) { stop in try extract(entry, archive, file, stop) }
    }

    /// `extract` on the calling thread.
    public static func extractSync(_ entry: String, from archive: URL, to file: URL, cancel: Shell.CancelFlag? = nil) throws {
        try extract(entry, archive, file, cancel ?? Shell.CancelFlag())
    }

    private static func extract(_ entry: String, _ archive: URL, _ file: URL, _ stop: Shell.CancelFlag) throws {
        guard try names(archive, stop).contains(entry) else { throw ArchiveError.missingEntry(entry) }
        let partial = try Staging.file(beside: file, purpose: "partial")
        do {
            let output = try Tool.run("/usr/bin/tar", ["-xOf", archive.path, "--", tarPattern(entry)],
                                      Shell.Options(stdout: .file(partial)), stop: stop)
            guard output.succeeded else { throw ArchiveError.toolFailed(Zip.failure(output)) }
            try Work.check(stop)
            try Staging.swap(partial, into: file, dispose: Disposal.delete.callAsFunction)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Writes several entries, each to its file (`["AM2R_11/data.win": …, "AM2R_11/AM2R.exe": …]`), in one
    /// pass over the archive: a solid 7z is decompressed once, not once per entry. Nothing is replaced
    /// until every one is written whole.
    public static func extract(_ entries: [String: URL], from archive: URL, cancel: Shell.CancelFlag? = nil) async throws {
        try await Work.run(cancel) { stop in try extract(entries, archive, stop) }
    }

    /// The same on the calling thread.
    public static func extractSync(_ entries: [String: URL], from archive: URL, cancel: Shell.CancelFlag? = nil) throws {
        try extract(entries, archive, cancel ?? Shell.CancelFlag())
    }

    private static func extract(_ wanted: [String: URL], _ archive: URL, _ stop: Shell.CancelFlag) throws {
        let sorted = wanted.sorted { $0.key < $1.key }
        guard let first = sorted.first else { return }
        let names = Set(try names(archive, stop))
        if let bad = sorted.first(where: { Safety.isUnsafe($0.key) }) { throw ArchiveError.unsafeEntry(bad.key) }
        if let missing = sorted.first(where: { !names.contains($0.key) }) { throw ArchiveError.missingEntry(missing.key) }
        let staging = try Staging.folder(beside: first.value, purpose: "extracting")
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = try Tool.run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path, "--"] + sorted.map { tarPattern($0.key) },
                                  Shell.Options(stdout: .discard), stop: stop)
        guard output.succeeded else { throw ArchiveError.toolFailed(Zip.failure(output)) }
        if let bad = Safety.escapingLink(in: staging) { throw ArchiveError.unsafeEntry(bad) }
        for (name, _) in sorted {
            let values = try? staging.appending(path: name).resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { throw ArchiveError.missingEntry(name) }
        }
        try Work.check(stop)
        for (name, file) in sorted {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Staging.swap(staging.appending(path: name), into: file, dispose: Disposal.delete.callAsFunction)
        }
    }

    // MARK: Unpacking

    /// Unpacks `archive` into `folder`, like `Zip.unpack`: names checked first, a hidden folder beside
    /// `folder`, moved into place when whole. A symbolic link pointing out refuses the whole archive.
    /// `dropsQuarantine` leaves the downloaded-file mark off what comes out (tar copies it from the archive).
    @discardableResult
    public static func unpack(_ archive: URL, into folder: URL, replacing: Bool = false, replaced: Disposal = .trash,
                              dropsQuarantine: Bool = false, cancel: Shell.CancelFlag? = nil) async throws -> URL {
        try await Work.run(cancel) { stop in try unpack(archive, folder, replacing, replaced, dropsQuarantine, stop) }
    }

    /// `unpack` on the calling thread.
    @discardableResult
    public static func unpackSync(_ archive: URL, into folder: URL, replacing: Bool = false, replaced: Disposal = .trash,
                                  dropsQuarantine: Bool = false, cancel: Shell.CancelFlag? = nil) throws -> URL {
        try unpack(archive, folder, replacing, replaced, dropsQuarantine, cancel ?? Shell.CancelFlag())
    }

    private static func unpack(_ archive: URL, _ folder: URL, _ replacing: Bool, _ replaced: Disposal, _ dropsQuarantine: Bool,
                               _ stop: Shell.CancelFlag) throws -> URL {
        if let bad = Zip.unsafeEntry(try names(archive, stop)) { throw ArchiveError.unsafeEntry(bad) }
        if !replacing, FileManager.default.fileExists(atPath: folder.path) { throw ArchiveError.exists(folder) }
        let staging = try Staging.folder(beside: folder, purpose: "unpacking")
        do {
            // Without -P, bsdtar also refuses "..", absolute paths and writing through a link.
            let output = try Tool.run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path], Shell.Options(stdout: .discard), stop: stop)
            guard output.succeeded else { throw ArchiveError.toolFailed(Zip.failure(output)) }
            if let bad = Safety.escapingLink(in: staging) { throw ArchiveError.unsafeEntry(bad) }
            if dropsQuarantine { Staging.dropQuarantine(in: staging) }
            try Work.check(stop)
            try Staging.swap(staging, into: folder, dispose: replaced.callAsFunction)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return folder
    }

    /// tar reads * ? [ ] \\ in a name as a pattern: escaped, the exact entry is read.
    static func tarPattern(_ name: String) -> String {
        var pattern = ""
        for character in name {
            if "*?[]\\".contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
        return pattern
    }
}
