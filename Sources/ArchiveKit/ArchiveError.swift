import Foundation

/// Why an archive couldn't be read, unpacked, packed, backed up or restored. Cancelling the task
/// throws `CancellationError` instead.
public enum ArchiveError: Error, LocalizedError, Sendable, Equatable {
    /// The file doesn't start like a zip. `size` is its size in bytes, to tell an empty or cut download.
    case notAZip(size: Int64)
    /// Its records are cut or don't add up.
    case damaged(String)
    /// An entry that would land outside the folder: an absolute path, "..", a drive letter, or a
    /// symbolic link pointing out. Nothing was written.
    case unsafeEntry(String)
    /// More bytes or entries than the limit given, or an entry read into memory past its limit.
    case tooLarge
    /// No entry with that name.
    case missingEntry(String)
    /// Something is already at the target and replacing wasn't asked for.
    case exists(URL)
    /// The folder to back up or pack has nothing in it.
    case nothingToBackUp
    /// The backup doesn't hold what the app expects (its `accept` check said no, or the items aren't there).
    case notABackup
    /// ditto, unzip, zip or tar failed; its last words.
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip(let size): size == 0 ? "This file is empty, not a zip." : "This file isn't a zip."
        case .damaged(let why): "This zip is damaged (\(why))."
        case .unsafeEntry(let name): "This archive tries to write outside its folder (“\(name)”), so nothing was unpacked."
        case .tooLarge: "This archive is too large."
        case .missingEntry(let name): "“\(name)” isn't in this archive."
        case .exists(let url): "“\(url.lastPathComponent)” is already there."
        case .nothingToBackUp: "There's nothing to back up."
        case .notABackup: "This zip isn't a backup of these files."
        case .toolFailed(let message): message
        }
    }
}
