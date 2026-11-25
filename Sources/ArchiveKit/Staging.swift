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

    /// Puts `incoming` at `target`. What was there is moved aside first and handed to `dispose` only once
    /// `incoming` is in place; when the move fails, it goes back.
    static func swap(_ incoming: URL, into target: URL, dispose: (URL) throws -> Void) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: target.path) || isLink(target) else {
            try files.moveItem(at: incoming, to: target)
            return
        }
        let old = try file(beside: target, purpose: "old")
        try files.moveItem(at: target, to: old)
        do {
            try files.moveItem(at: incoming, to: target)
        } catch {
            try? files.moveItem(at: old, to: target)
            throw error
        }
        // The new one is in place: when the old one can't go (the Trash refused), it stays beside it, hidden,
        // rather than being deleted or failing a swap that worked.
        try? dispose(old)
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
    /// The app's own way (a Trash that tests can watch, a recycle folder).
    case custom(@Sendable (URL) throws -> Void)

    func callAsFunction(_ url: URL) throws {
        switch self {
        case .delete: try FileManager.default.removeItem(at: url)
        case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        case .custom(let dispose): try dispose(url)
        }
    }
}
