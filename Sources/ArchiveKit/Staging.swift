import Foundation

/// Work beside the target, on the same disk, so the last step is a rename.
enum Staging {
    /// A new hidden folder beside `target`: ".<name>.<purpose>-<id>".
    static func folder(beside target: URL, purpose: String) throws -> URL {
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appending(path: ".\(target.lastPathComponent).\(purpose)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// A path beside `target` for a file not made yet.
    static func file(beside target: URL, purpose: String) throws -> URL {
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appending(path: ".\(target.lastPathComponent).\(purpose)-\(UUID().uuidString)")
    }

    /// Puts `incoming` at `target`. What was there is moved aside first, into a hidden folder under its own
    /// name (so it reaches the Trash as "Saves", not as a hidden work name), and handed to `dispose` only
    /// once `incoming` is in place; when the move fails, it goes back.
    static func swap(_ incoming: URL, into target: URL, dispose: (URL) throws -> Void) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: target.path) || isLink(target) else {
            try files.moveItem(at: incoming, to: target)
            return
        }
        let holder = try folder(beside: target, purpose: "old")
        let old = holder.appending(path: target.lastPathComponent)
        do {
            try files.moveItem(at: target, to: old)
        } catch {
            try? files.removeItem(at: holder)
            throw error
        }
        do {
            try files.moveItem(at: incoming, to: target)
        } catch {
            try? files.moveItem(at: old, to: target)
            try? files.removeItem(at: holder)
            throw error
        }
        // The new one is in place: when the old one can't go (the Trash refused), it stays beside it, hidden,
        // rather than being deleted or failing a swap that worked.
        guard (try? dispose(old)) != nil else { return }
        if (try? files.contentsOfDirectory(atPath: holder.path))?.isEmpty == true { try? files.removeItem(at: holder) }
    }

    /// Takes the downloaded-file mark off everything in `folder`.
    static func dropQuarantine(in folder: URL) {
        removexattr(folder.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let walker = FileManager.default.enumerator(atPath: folder.path)
        while let relative = walker?.nextObject() as? String {
            removexattr(folder.appending(path: relative).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}

/// What happens to a file or folder ArchiveKit replaces or prunes.
public enum Disposal: Sendable {
    /// Removed at once.
    case delete
    /// Moved to the Trash, where it can come back from.
    case trash
    /// The app's own way (a Trash that tests can watch, a recycle folder). The URL it gets has the
    /// replaced item's own name ("Saves", "report.zip"), in a hidden folder beside the target.
    case custom(@Sendable (URL) throws -> Void)

    /// Moved to the Trash under its own name, then `moved` is told where it went (to offer Put Back or Undo).
    public static func trash(reporting moved: @escaping @Sendable (_ inTrash: URL) -> Void) -> Disposal {
        .custom { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            moved((result as URL?) ?? url)
        }
    }

    func callAsFunction(_ url: URL) throws {
        switch self {
        case .delete: try FileManager.default.removeItem(at: url)
        case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        case .custom(let dispose): try dispose(url)
        }
    }
}
