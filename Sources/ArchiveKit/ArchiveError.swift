import Foundation

/// Why an archive couldn't be read, unpacked, packed, backed up or restored. Cancelling the task
/// throws `CancellationError` instead.
///
/// `localizedDescription` is a sentence an app can show as it is, in the app's language: French when
/// the app runs in French (`Bundle.main.preferredLocalizations`, so the app's own language setting
/// counts), English otherwise.
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

    public var errorDescription: String? { message(language: Self.appLanguage) }

    /// The sentence in a language of your choice: "fr" (or "fr-CA"…) for French, anything else for English.
    public func message(language: String) -> String {
        Self.isFrench(language) ? french : english
    }

    private var english: String {
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

    // French spacing: a no-break space inside « » and before : ; ! ?
    private var french: String {
        switch self {
        case .notAZip(let size): size == 0 ? "Ce fichier est vide, ce n’est pas un zip." : "Ce fichier n’est pas un zip."
        case .damaged(let why): "Ce zip est endommagé (\(why))."
        case .unsafeEntry(let name): "Cette archive tente d’écrire hors de son dossier («\u{00A0}\(name)\u{00A0}»), rien n’a donc été décompressé."
        case .tooLarge: "Cette archive est trop volumineuse."
        case .missingEntry(let name): "«\u{00A0}\(name)\u{00A0}» ne se trouve pas dans cette archive."
        case .exists(let url): "«\u{00A0}\(url.lastPathComponent)\u{00A0}» existe déjà."
        case .nothingToBackUp: "Il n’y a rien à sauvegarder."
        case .notABackup: "Ce zip n’est pas une sauvegarde de ces fichiers."
        case .toolFailed(let message): message
        }
    }

    /// The language the app runs in.
    static var appLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    static func isFrench(_ language: String) -> Bool { language.lowercased().hasPrefix("fr") }
}
