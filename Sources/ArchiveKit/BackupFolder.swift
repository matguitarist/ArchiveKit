import Foundation

/// A folder of zipped backups: "2026-11-24 14.05.09 - Before restore.zip". Backing up writes beside
/// the target and moves the zip into place; restoring unpacks beside the folder and swaps it in, so a
/// failed restore leaves the current files as they were.
public struct BackupFolder: Sendable {
    /// One backup zip.
    public struct Backup: Sendable, Hashable, Identifiable {
        public let url: URL
        /// When it was written.
        public let date: Date
        /// Bytes on disk.
        public let size: Int64
        public var id: URL { url }
        /// The file name without ".zip".
        public var name: String { url.deletingPathExtension().lastPathComponent }
        /// What follows " - " in the name ("Before restore"), without the number a same-second twin got.
        public var label: String? {
            guard let range = name.range(of: " - ") else { return nil }
            let rest = String(name[range.upperBound...])
            let number = UniqueName.number(in: rest)
            return number > 1 ? String(rest.dropLast(" \(number)".count)) : rest
        }
    }

    public let root: URL
    /// What happens to pruned backups and to the files a restore replaces.
    public let disposal: Disposal

    public init(root: URL, disposal: Disposal = .trash) {
        self.root = root
        self.disposal = disposal
    }

    /// "2026-11-24 14.05.09", sorting as text in date order.
    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    // MARK: Backing up

    /// Zips `folder` into a new backup and returns it.
    /// - Parameters:
    ///   - items: names inside `folder` to back up, at the top of the zip; nil for everything in it.
    ///     Names that aren't there are skipped.
    ///   - keepParent: the folder itself as the zip's top entry; false puts its content at the top.
    ///   - name: the file name without ".zip"; nil for the date stamp. " - label" follows it, and " 2",
    ///     " 3" when it's taken.
    ///   - macMetadata: false for a plain zip other tools (and other systems) read the same.
    /// Throws `.nothingToBackUp` when there's nothing but hidden files to back up.
    @discardableResult
    public func backUp(
        from folder: URL, items: [String]? = nil, keepParent: Bool = false,
        name: String? = nil, label: String? = nil, date: Date = .now, macMetadata: Bool = true
    ) async throws -> Backup {
        let files = FileManager.default
        let present = (items ?? ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []))
            .filter { !$0.hasPrefix(".") && files.fileExists(atPath: folder.appending(path: $0).path) }
        guard !present.isEmpty else { throw ArchiveError.nothingToBackUp }
        try files.createDirectory(at: root, withIntermediateDirectories: true)

        var base = clean(name ?? Self.stamp(date))
        if let label, !label.isEmpty { base += " - " + clean(label) }
        let zip = UniqueName.url(for: base + ".zip", in: root)
        try await Zip.pack(folder, to: zip, items: items == nil ? nil : present, keepParent: keepParent, macMetadata: macMetadata)
        return try backup(at: zip)
    }

    // MARK: Listing

    /// Every backup, newest first. Hidden files (a backup being written) are left out.
    public func list() -> [Backup] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "zip" }
            .compactMap { try? backup(at: $0) }
            .sorted(by: Self.newerFirst)
    }

    /// Newest first; two made in the same second by the number the second one got.
    static func newerFirst(_ a: Backup, _ b: Backup) -> Bool {
        if a.date != b.date { return a.date > b.date }
        let numberA = UniqueName.number(in: a.name), numberB = UniqueName.number(in: b.name)
        if numberA != numberB { return numberA > numberB }
        return a.name > b.name
    }

    /// The backup a zip in this folder is.
    public func backup(at url: URL) throws -> Backup {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Backup(url: url, date: values.contentModificationDate ?? .distantPast, size: Int64(values.fileSize ?? 0))
    }

    // MARK: Restoring

    /// Puts a backup in place of `folder`'s content, or of only `items` in it.
    ///
    /// The zip is checked and unpacked beside `folder` first. Without `items`, its content (its top, or
    /// its only folder when it holds one folder) replaces `folder` in one move, and the old folder goes
    /// to `disposal`. With `items`, each of those top-level names replaces the one in `folder`; the
    /// others stay. Make a "Before restore" backup first when the current files matter.
    /// - Parameter accept: the app's check that the content is a backup of its files (a saves folder);
    ///   when it says no, `.notABackup` is thrown and nothing changes.
    public func restore(_ backup: Backup, into folder: URL, items: [String]? = nil,
                        accept: (@Sendable (URL) -> Bool)? = nil) async throws {
        let files = FileManager.default
        let staging = try Staging.file(beside: folder, purpose: "restoring")
        defer { try? files.removeItem(at: staging) }
        do {
            try await Zip.unpack(backup.url, into: staging)
        } catch let error as ArchiveError {
            if case .unsafeEntry = error { throw error }
            throw ArchiveError.notABackup
        }
        var content = Zip.contentFolder(staging)
        if let accept, content != staging, accept(staging) { content = staging }
        if let accept, !accept(content) { throw ArchiveError.notABackup }

        if let items {
            let present = items.filter { !Safety.isUnsafe($0) && files.fileExists(atPath: content.appending(path: $0).path) }
            guard !present.isEmpty else { throw ArchiveError.notABackup }
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in present {
                try Staging.swap(content.appending(path: item), into: folder.appending(path: item), dispose: disposal.callAsFunction)
            }
        } else {
            try Staging.swap(content, into: folder, dispose: disposal.callAsFunction)
        }
    }

    // MARK: Pruning

    /// Keeps the newest `keep` backups that `matching` picks (all by default) and disposes of the rest.
    /// Returns those removed.
    @discardableResult
    public func prune(keep: Int, matching: (Backup) -> Bool = { _ in true }) throws -> [Backup] {
        let old = Array(list().filter(matching).dropFirst(max(keep, 0)))
        for backup in old { try disposal(backup.url) }
        return old
    }

    /// Disposes of one backup.
    public func delete(_ backup: Backup) throws {
        try disposal(backup.url)
    }

    /// "/" and ":" can't be in a file name.
    private func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
