import Foundation

/// The Zip Slip rules, shared by zips and other archives.
enum Safety {
    /// Whether a name inside an archive could land outside the folder it's unpacked into:
    /// empty, absolute ("/" or "\\"), a drive letter ("C:"), a NUL, or any ".." part.
    static func isUnsafe(_ name: String) -> Bool {
        if name.isEmpty || name.hasPrefix("/") || name.hasPrefix("\\") || name.contains("\0") { return true }
        let scalars = Array(name.unicodeScalars)
        if scalars.count >= 2, scalars[1] == ":", CharacterSet.letters.contains(scalars[0]) { return true }
        return parts(name).contains("..")
    }

    /// The parts of a path, split at "/" and "\\", without "." and empty ones.
    static func parts(_ name: String) -> [String] {
        name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init).filter { $0 != "." }
    }

    /// Whether a symbolic link at `name` pointing at `target` leads outside the root.
    static func linkEscapes(_ name: String, target: String?) -> Bool {
        guard let target, !target.isEmpty, !target.hasPrefix("/"), !target.hasPrefix("\\"), !target.contains("\0") else { return true }
        var depth = parts(name).count - 1
        for part in parts(target) {
            depth += part == ".." ? -1 : 1
            if depth < 0 { return true }
        }
        return false
    }

    /// The first unsafe entry: a bad name, a link pointing out, or an entry inside a link
    /// (a link to a folder, then a file written through it, is the classic escape).
    static func firstUnsafe(_ entries: [Zip.Entry]) -> String? {
        var links: Set<String> = []
        for entry in entries where entry.isSymlink { links.insert(parts(entry.name).joined(separator: "/")) }
        for entry in entries {
            if isUnsafe(entry.name) { return entry.name }
            if entry.isSymlink, linkEscapes(entry.name, target: entry.linkTarget) { return entry.name }
            let path = parts(entry.name)
            if path.count > 1, !links.isEmpty {
                for length in 1..<path.count where links.contains(path[0..<length].joined(separator: "/")) { return entry.name }
            }
        }
        return nil
    }

    /// After unpacking: the first symbolic link under `folder` that points outside it, as a path
    /// relative to it. A second guard behind the checks made before.
    static func escapingLink(in folder: URL) -> String? {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return nil }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let relative = String(url.path.dropFirst(folder.path.count + 1))
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return relative }
            if target.hasPrefix("/") {
                let resolved = URL(fileURLWithPath: target).standardizedFileURL.path
                if resolved != root, !resolved.hasPrefix(root + "/") { return relative }
            } else if linkEscapes(relative, target: target) {
                return relative
            }
        }
        return nil
    }
}
