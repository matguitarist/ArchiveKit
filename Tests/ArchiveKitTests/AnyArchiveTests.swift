import Foundation
import ProcessKit
import Testing
@testable import ArchiveKit

@Suite struct AnyArchiveTests {
    @Test func listsReadsAndUnpacksATarball() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("pak", to: root.appending(path: "src/Mod/Mod [v2].pak"))
        try writeText("readme", to: root.appending(path: "src/Mod/readme.txt"))
        let archive = root.appending(path: "mod.tar.gz")
        try await Shell.run("/usr/bin/tar", ["-czf", archive.path, "Mod"], in: root.appending(path: "src")).check()

        let names = try await AnyArchive.names(archive)
        #expect(Set(names) == ["Mod/", "Mod/Mod [v2].pak", "Mod/readme.txt"])
        #expect(try await AnyArchive.read("Mod/Mod [v2].pak", from: archive, limit: 10) == Data("pak".utf8))
        await #expect(throws: ArchiveError.tooLarge) { try await AnyArchive.read("Mod/readme.txt", from: archive, limit: 2) }
        await #expect(throws: ArchiveError.missingEntry("x")) { try await AnyArchive.read("x", from: archive, limit: 2) }

        let file = root.appending(path: "one/readme.txt")
        try await AnyArchive.extract("Mod/readme.txt", from: archive, to: file)
        #expect(readText(file) == "readme")

        let out = try await AnyArchive.unpack(archive, into: root.appending(path: "out"))
        #expect(readText(out.appending(path: "Mod/Mod [v2].pak")) == "pak")
        #expect(!contents(root).contains { $0.hasPrefix(".") })
    }

    @Test func refusesDotDotNames() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("evil", to: root.appending(path: "src/evil.txt"))
        let archive = root.appending(path: "evil.tar")
        // bsdtar's -s renames the entry as it's stored.
        try await Shell.run("/usr/bin/tar", ["-cf", archive.path, "-s", ",^,../../,", "evil.txt"], in: root.appending(path: "src")).check()
        #expect(try await AnyArchive.names(archive) == ["../../evil.txt"])
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        await #expect(throws: ArchiveError.unsafeEntry("../../evil.txt")) {
            try await AnyArchive.unpack(archive, into: work.appending(path: "out"))
        }
        #expect(contents(work).isEmpty)
    }

    @Test func refusesALinkPointingOut() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: source.appending(path: "docs").path, withDestinationPath: "/tmp")
        let archive = root.appending(path: "link.tar")
        try await Shell.run("/usr/bin/tar", ["-cf", archive.path, "docs"], in: source).check()
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        await #expect(throws: ArchiveError.unsafeEntry("docs")) { try await AnyArchive.unpack(archive, into: work.appending(path: "out")) }
        #expect(contents(work).isEmpty)
    }

    @Test func aBrokenArchiveFails() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appending(path: "bad.7z")
        try writeText("not an archive", to: archive)
        await #expect(throws: ArchiveError.self) { try await AnyArchive.unpack(archive, into: root.appending(path: "out")) }
        #expect(contents(root) == ["bad.7z"])
    }
}

@Suite struct UniqueNameTests {
    @Test func numbersBeforeTheExtension() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(UniqueName.name(for: "Backup.zip", in: root) == "Backup.zip")
        try writeText("", to: root.appending(path: "Backup.zip"))
        #expect(UniqueName.name(for: "Backup.zip", in: root) == "Backup 2.zip")
        try writeText("", to: root.appending(path: "Backup 2.zip"))
        #expect(UniqueName.url(for: "Backup.zip", in: root).lastPathComponent == "Backup 3.zip")
        try FileManager.default.createDirectory(at: root.appending(path: "My.Project"), withIntermediateDirectories: true)
        #expect(UniqueName.name(for: "My.Project", in: root, isFolder: true) == "My.Project 2")
    }

    @Test func splitsAndReadsNumbers() {
        #expect(UniqueName.split("Save.tar.gz") == ("Save.tar", "gz"))
        #expect(UniqueName.split(".hidden") == (".hidden", ""))
        #expect(UniqueName.split("folder.d", isFolder: true) == ("folder.d", ""))
        #expect(UniqueName.number(in: "Auto 3") == 3)
        #expect(UniqueName.number(in: "Auto") == 1)
        #expect(UniqueName.number(in: "Year 1") == 1)
    }
}
