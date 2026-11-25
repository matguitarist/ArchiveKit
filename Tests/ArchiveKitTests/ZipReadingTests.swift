import Foundation
import Testing
@testable import ArchiveKit

@Suite struct ZipReadingTests {
    @Test func readsEntriesFromTheDirectory() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("print('hi')", to: root.appending(path: "src/Game/game/script.rpy"))
        try writeText(String(repeating: "x", count: 10_000), to: root.appending(path: "src/Game/big.txt"))
        let zip = root.appending(path: "game.zip")
        try await infoZip(["Game"], in: root.appending(path: "src"), to: zip)

        #expect(Zip.isZip(zip))
        let entries = try Zip.entries(zip)
        let names = entries.map(\.name)
        #expect(names.contains("Game/"))
        #expect(names.contains("Game/game/script.rpy"))
        let big = try #require(entries.first { $0.name == "Game/big.txt" })
        #expect(big.size == 10_000)
        #expect(big.compressedSize < 10_000)
        #expect(big.method == 8)
        #expect(entries.first { $0.name == "Game/" }?.isDirectory == true)
        #expect(try Zip.uncompressedSize(zip) == 10_011)
        #expect(Zip.topLevelNames(entries) == ["Game"])
        #expect(Zip.unsafeEntry(entries) == nil)
    }

    @Test func aFileThatIsntAZip() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appending(path: "notes.zip")
        try writeText("not a zip at all", to: text)
        #expect(!Zip.isZip(text))
        #expect(throws: ArchiveError.notAZip(size: 16)) { try Zip.entries(text) }
        let empty = root.appending(path: "empty.zip")
        try Data().write(to: empty)
        #expect(throws: ArchiveError.notAZip(size: 0)) { try Zip.entries(empty) }
        #expect(throws: ArchiveError.notAZip(size: 0)) { try Zip.entries(root.appending(path: "missing.zip")) }
    }

    @Test func aCutZipIsDamaged() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var maker = ZipMaker()
        maker.file("a.txt", "hello")
        let zip = root.appending(path: "a.zip")
        try maker.write(to: zip)
        let whole = try Data(contentsOf: zip)
        try whole.prefix(whole.count - 30).write(to: zip)
        #expect(throws: ArchiveError.self) { try Zip.entries(zip) }
    }

    @Test func readsZIP64Records() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var maker = ZipMaker()
        maker.file("one.txt", "1")
        maker.file("two/three.txt", "33")
        let zip = root.appending(path: "big.zip")
        try maker.write(to: zip, zip64: true)
        #expect(try Zip.names(zip) == ["one.txt", "two/three.txt"])
        #expect(try Zip.uncompressedSize(zip) == 3)
    }

    @Test func readsSymbolicLinksAndWhereTheyPoint() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var maker = ZipMaker()
        maker.file("lib/real.dylib", "binary")
        maker.link("lib/current.dylib", to: "real.dylib")
        let zip = root.appending(path: "links.zip")
        try maker.write(to: zip)
        let link = try #require(try Zip.entries(zip).first { $0.isSymlink })
        #expect(link.name == "lib/current.dylib")
        #expect(link.linkTarget == "real.dylib")
        #expect(Zip.unsafeEntry(try Zip.entries(zip)) == nil)
    }

    @Test func macMetadataIsMarked() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var maker = ZipMaker()
        maker.file("Saves/save1", "s")
        maker.file("__MACOSX/Saves/._save1", "fork")
        let zip = root.appending(path: "m.zip")
        try maker.write(to: zip)
        let entries = try Zip.entries(zip)
        #expect(entries.filter(\.isMacMetadata).map(\.name) == ["__MACOSX/Saves/._save1"])
        #expect(Zip.topLevelNames(entries) == ["Saves"])
    }
}

@Suite struct UnsafeNameTests {
    @Test func namesThatStayInside() {
        #expect(Zip.unsafeEntry(["Game/game/script.rpy", "Game/./lib/", "a b/c:d.txt", "dots..txt", "...", ".hidden"]) == nil)
    }

    @Test func namesThatEscape() {
        #expect(Zip.unsafeEntry(["Game/../../evil.sh"]) == "Game/../../evil.sh")
        #expect(Zip.unsafeEntry(["/etc/passwd"]) == "/etc/passwd")
        #expect(Zip.unsafeEntry(["a/b/../../../c"]) == "a/b/../../../c")
        #expect(Zip.unsafeEntry(["game/ok.rpy", "../../evil.rpy"]) == "../../evil.rpy")
        #expect(Zip.unsafeEntry(["..\\windows.dll"]) == "..\\windows.dll")
        #expect(Zip.unsafeEntry(["\\server\\share"]) == "\\server\\share")
        #expect(Zip.unsafeEntry(["C:/Windows/evil.exe"]) == "C:/Windows/evil.exe")
        #expect(Zip.unsafeEntry(["c:evil"]) == "c:evil")
        #expect(Zip.unsafeEntry([""]) == "")
        #expect(Zip.unsafeEntry(["a/../b"]) == "a/../b")
    }

    @Test func linksThatEscape() {
        func entry(_ name: String, link: String? = nil) -> Zip.Entry {
            Zip.Entry(name: name, size: 0, compressedSize: 0, method: 0, crc32: 0, isDirectory: false,
                      isSymlink: link != nil, linkTarget: link)
        }
        #expect(Zip.unsafeEntry([entry("a/l", link: "../b")]) == nil)
        #expect(Zip.unsafeEntry([entry("a/l", link: "../../b")]) == "a/l")
        #expect(Zip.unsafeEntry([entry("l", link: "/etc")]) == "l")
        #expect(Zip.unsafeEntry([entry("l", link: "")]) == "l")
        // A link to a folder inside, then a file written through it: refused all the same.
        #expect(Zip.unsafeEntry([entry("l", link: "sub"), entry("l/file")]) == "l/file")
    }
}
