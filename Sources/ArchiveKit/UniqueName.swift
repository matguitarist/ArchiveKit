import Foundation

/// A name nothing in a folder has yet: the name itself when free, then "name 2", "name 3"…,
/// before the extension ("Backup 2.zip"). Folders have no extension; packages (.app) do.
public enum UniqueName {
    public static func name(for name: String, in folder: URL, isFolder: Bool = false) -> String {
        let (stem, ext) = split(name, isFolder: isFolder)
        var candidate = name
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: candidate).path) {
            candidate = "\(stem) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
            number += 1
        }
        return candidate
    }

    /// The same, as a URL in `folder`.
    public static func url(for name: String, in folder: URL, isFolder: Bool = false) -> URL {
        folder.appending(path: self.name(for: name, in: folder, isFolder: isFolder), directoryHint: isFolder ? .isDirectory : .notDirectory)
    }

    /// The name and its extension: "Save.tar.gz" is ("Save.tar", "gz"); ".hidden" has none.
    public static func split(_ name: String, isFolder: Bool = false) -> (stem: String, ext: String) {
        guard !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex
        else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// The number a name got to be unique: 3 for "Auto 3", 1 for "Auto".
    public static func number(in stem: String) -> Int {
        guard let space = stem.lastIndex(of: " "), let number = Int(stem[stem.index(after: space)...]), number >= 2 else { return 1 }
        return number
    }
}
