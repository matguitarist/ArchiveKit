import Foundation
import ProcessKit

/// Any archive macOS's tar (bsdtar, libarchive) reads: 7z, RAR, tar, tar.gz, tar.bz2, xz, and zip too.
/// No third-party tool. Names are checked before anything is written, and unpacking happens beside
/// the target, moved into place when whole, then checked again for links pointing out.
public enum AnyArchive {
    /// The extensions worth trying: zip goes through `Zip` for its macOS metadata.
    public static let extensions: Set<String> = ["7z", "rar", "tar", "tgz", "gz", "bz2", "tbz", "tbz2", "xz", "txz", "zip"]

    /// The names inside, as tar lists them (folders end with "/").
    public static func names(_ archive: URL) async throws -> [String] {
        let output = try await Shell.run("/usr/bin/tar", ["-tf", archive.path])
        guard output.succeeded else { throw ArchiveError.toolFailed(Zip.failure(output)) }
        return output.lines.filter { !$0.isEmpty }
    }

    /// One entry's bytes, read into memory; `.tooLarge` past `limit` bytes.
    public static func read(_ entry: String, from archive: URL, limit: Int) async throws -> Data {
        guard try await names(archive).contains(entry) else { throw ArchiveError.missingEntry(entry) }
        let output = try await Shell.run("/usr/bin/tar", ["-xOf", archive.path, "--", tarPattern(entry)],
                                         options: Shell.Options(outputLimit: limit))
        if output.truncated { throw ArchiveError.tooLarge }
        guard output.succeeded else { throw ArchiveError.toolFailed(Zip.failure(output)) }
        return output.stdout
    }

    /// Writes one entry to `file` (replaced when there), streaming.
    public static func extract(_ entry: String, from archive: URL, to file: URL) async throws {
        guard try await names(archive).contains(entry) else { throw ArchiveError.missingEntry(entry) }
        let partial = try Staging.file(beside: file, purpose: "partial")
        do {
            let output = try await Shell.run("/usr/bin/tar", ["-xOf", archive.path, "--", tarPattern(entry)],
                                             options: Shell.Options(stdout: .file(partial)))
            guard output.succeeded else { throw ArchiveError.toolFailed(Zip.failure(output)) }
            try Staging.swap(partial, into: file, dispose: Disposal.delete.callAsFunction)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Unpacks `archive` into `folder`, like `Zip.unpack`: names checked first, a hidden folder beside
    /// `folder`, moved into place when whole. A symbolic link pointing out refuses the whole archive.
    @discardableResult
    public static func unpack(_ archive: URL, into folder: URL, replacing: Bool = false, replaced: Disposal = .trash) async throws -> URL {
        if let bad = Zip.unsafeEntry(try await names(archive)) { throw ArchiveError.unsafeEntry(bad) }
        if !replacing, FileManager.default.fileExists(atPath: folder.path) { throw ArchiveError.exists(folder) }
        let staging = try Staging.folder(beside: folder, purpose: "unpacking")
        do {
            // Without -P, bsdtar also refuses "..", absolute paths and writing through a link.
            let output = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path],
                                             options: Shell.Options(stdout: .discard))
            guard output.succeeded else { throw ArchiveError.toolFailed(Zip.failure(output)) }
            if let bad = Safety.escapingLink(in: staging) { throw ArchiveError.unsafeEntry(bad) }
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
