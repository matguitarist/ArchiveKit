import Foundation
import Testing
@testable import ArchiveKit

@Suite struct ZipPackTests {
    func sample(_ root: URL) throws -> URL {
        let folder = root.appending(path: "Saves", directoryHint: .isDirectory)
        try writeText("one", to: folder.appending(path: "save1"))
        try writeText("ini", to: folder.appending(path: "config.ini"))
        try writeText("deep", to: folder.appending(path: "sub/deep.txt"))
        return folder
    }

    @Test func packsAFolderContentAtTheTop() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try await Zip.pack(try sample(root), to: root.appending(path: "out/backup.zip"))
        #expect(try fileNames(zip) == ["save1", "config.ini", "sub/deep.txt"])
        #expect(contents(root.appending(path: "out")) == ["backup.zip"])
        try await Zip.test(zip)
    }

    @Test func keepParentPutsTheFolderAtTheTop() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try await Zip.pack(try sample(root), to: root.appending(path: "b.zip"), keepParent: true)
        #expect(Zip.topLevelNames(try Zip.entries(zip)) == ["Saves"])
    }

    @Test func aFileIsAtTheTop() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("rom", to: root.appending(path: "Game.sfc"))
        let zip = try await Zip.pack(root.appending(path: "Game.sfc"), to: root.appending(path: "Game.zip"), keepParent: true, level: 9)
        #expect(try fileNames(zip) == ["Game.sfc"])
    }

    @Test func itemsGoAtTheTopAndMissingOnesAreSkipped() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try sample(root)
        let zip = try await Zip.pack(folder, to: root.appending(path: "i.zip"), items: ["sub", "save1", "gone"], macMetadata: false)
        #expect(Set(Zip.topLevelNames(try Zip.entries(zip))) == ["sub", "save1"])
        #expect(contents(root).filter { $0.hasPrefix(".") }.isEmpty)
        await #expect(throws: ArchiveError.nothingToBackUp) { try await Zip.pack(folder, to: root.appending(path: "n.zip"), items: ["gone"]) }
    }

    @Test func anExistingZipStaysUnlessReplacing() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try sample(root)
        let zip = root.appending(path: "b.zip")
        try writeText("old", to: zip)
        await #expect(throws: ArchiveError.exists(zip)) { try await Zip.pack(folder, to: zip) }
        #expect(readText(zip) == "old")
        try await Zip.pack(folder, to: zip, replacing: true)
        #expect(Zip.isZip(zip))
    }

    @Test func packedAndUnpackedIsTheSame() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try sample(root)
        let zip = try await Zip.pack(folder, to: root.appending(path: "r.zip"))
        let out = try await Zip.unpack(zip, into: root.appending(path: "back"))
        #expect(contents(out) == contents(folder))
        #expect(readText(out.appending(path: "sub/deep.txt")) == "deep")
    }
}

@Suite struct ZipEntryTests {
    @Test func readsOneEntryWithPatternCharactersInItsName() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var maker = ZipMaker()
        maker.file("Super Metroid [!] (*).sfc", "the rom")
        maker.file("Super Metroid [a].sfc", "another")
        let zip = root.appending(path: "rom.zip")
        try maker.write(to: zip)
        #expect(try await Zip.read("Super Metroid [!] (*).sfc", from: zip, limit: 100) == Data("the rom".utf8))
        await #expect(throws: ArchiveError.tooLarge) { try await Zip.read("Super Metroid [a].sfc", from: zip, limit: 3) }
        await #expect(throws: ArchiveError.missingEntry("nope")) { try await Zip.read("nope", from: zip, limit: 3) }
    }

    @Test func extractsOneEntryToAFile() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText(String(repeating: "data.win ", count: 50_000), to: root.appending(path: "src/Mod/data.win"))
        try writeText("music", to: root.appending(path: "src/Mod/music.ogg"))
        let zip = root.appending(path: "mod.zip")
        try await infoZip(["Mod"], in: root.appending(path: "src"), to: zip)
        let target = root.appending(path: "game/data.win")
        try writeText("old", to: target)
        try await Zip.extract("Mod/data.win", from: zip, to: target)
        #expect(readText(target) == String(repeating: "data.win ", count: 50_000))
        #expect(contents(root.appending(path: "game")) == ["data.win"])
        await #expect(throws: ArchiveError.missingEntry("Mod/")) { try await Zip.extract("Mod/", from: zip, to: target) }
    }
}
