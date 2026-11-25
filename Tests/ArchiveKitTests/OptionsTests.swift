import CryptoKit
import Foundation
import ProcessKit
import Testing
@testable import ArchiveKit

/// 3 MB that compress a little: several 1 MB chunks in and out of the inflater.
func bigData() -> Data {
    var generator = SystemRandomNumberGenerator()
    var data = Data(capacity: 3 << 20)
    while data.count < 3 << 20 {
        data.append(contentsOf: (0..<4096).map { _ in UInt8.random(in: 0...15, using: &generator) })
        data.append(Data(repeating: 7, count: 4096))
    }
    return data
}

func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Suite struct StreamTests {
    @Test func readsHashesAndStreamsADeflatedEntrySynchronously() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = bigData()
        try FileManager.default.createDirectory(at: root.appending(path: "src/AM2R_11"), withIntermediateDirectories: true)
        try data.write(to: root.appending(path: "src/AM2R_11/data.win"))
        try writeText("exe", to: root.appending(path: "src/AM2R_11/AM2R.exe"))
        let zip = root.appending(path: "am2r.zip")
        try Shell.runSync("/usr/bin/zip", ["-qr", zip.path, "AM2R_11"], in: root.appending(path: "src")).check()
        #expect(try Zip.entries(zip).first { $0.name == "AM2R_11/data.win" }?.method == 8)

        #expect(try Zip.hashSync("AM2R_11/data.win", from: zip, using: Insecure.MD5.self) == md5(data))
        #expect(try Zip.readSync("AM2R_11/data.win", from: zip, limit: 4 << 20) == data)
        #expect(throws: ArchiveError.tooLarge) { try Zip.readSync("AM2R_11/data.win", from: zip, limit: 1 << 20) }
        var chunks = 0
        var total = 0
        try Zip.stream("AM2R_11/data.win", from: zip) { chunk in
            #expect(chunk.count <= 1 << 20)
            chunks += 1
            total += chunk.count
        }
        #expect(chunks >= 3 && total == data.count)
        let target = root.appending(path: "out/data.win")
        try Zip.extractSync("AM2R_11/data.win", from: zip, to: target)
        #expect(try Data(contentsOf: target) == data)
        #expect(throws: ArchiveError.missingEntry("AM2R_11/")) { try Zip.readSync("AM2R_11/", from: zip, limit: 10) }
    }

    @Test func hashesAsync() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("rom", to: root.appending(path: "src/Game.sfc"))
        let zip = root.appending(path: "g.zip")
        try await infoZip(["Game.sfc"], in: root.appending(path: "src"), to: zip)
        #expect(try await Zip.hash("Game.sfc", from: zip, using: SHA256.self) == SHA256.hash(data: Data("rom".utf8)).map { String(format: "%02x", $0) }.joined())
    }

    @Test func aStoredEntryWithAWrongCRCIsDamaged() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var maker = ZipMaker()
        maker.file("good.txt", "fine")
        maker.items.append(.init(name: "bad.txt", data: Data("broken".utf8), badCRC: true))
        let zip = root.appending(path: "c.zip")
        try maker.write(to: zip)
        #expect(try Zip.readSync("good.txt", from: zip, limit: 10) == Data("fine".utf8))
        #expect(throws: ArchiveError.damaged("bad.txt fails its CRC check")) { try Zip.readSync("bad.txt", from: zip, limit: 10) }
        let target = root.appending(path: "bad.txt")
        #expect(throws: ArchiveError.self) { try Zip.extractSync("bad.txt", from: zip, to: target) }
        #expect(contents(root) == ["c.zip"])
    }

    @Test func extractsSeveralEntriesOrNone() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("data", to: root.appending(path: "src/AM2R_11/data.win"))
        try writeText("exe", to: root.appending(path: "src/AM2R_11/AM2R.exe"))
        let zip = root.appending(path: "a.zip")
        try await infoZip(["AM2R_11"], in: root.appending(path: "src"), to: zip)
        let work = root.appending(path: "work")
        try await Zip.extract(["AM2R_11/data.win": work.appending(path: "data.win"), "AM2R_11/AM2R.exe": work.appending(path: "AM2R.exe")], from: zip)
        #expect(contents(work) == ["AM2R.exe", "data.win"])
        let other = root.appending(path: "other")
        await #expect(throws: ArchiveError.missingEntry("nope")) {
            try await Zip.extract(["AM2R_11/data.win": other.appending(path: "data.win"), "nope": other.appending(path: "x")], from: zip)
        }
        #expect(contents(other).isEmpty)
    }

    @Test func sevenZipSyncReadsHashesAndSeveralEntriesInOnePass() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = bigData()
        try FileManager.default.createDirectory(at: root.appending(path: "src/AM2R_11"), withIntermediateDirectories: true)
        try data.write(to: root.appending(path: "src/AM2R_11/data.win"))
        try writeText("exe", to: root.appending(path: "src/AM2R_11/AM2R.exe"))
        try writeText("[x]", to: root.appending(path: "src/AM2R_11/odd [1].txt"))
        let archive = root.appending(path: "am2r.7z")
        try Shell.runSync("/usr/bin/tar", ["--format", "7zip", "-cf", archive.path, "AM2R_11"], in: root.appending(path: "src")).check()

        #expect(Set(try AnyArchive.namesSync(archive)).isSuperset(of: ["AM2R_11/data.win", "AM2R_11/AM2R.exe"]))
        #expect(try AnyArchive.hashSync("AM2R_11/data.win", from: archive, using: Insecure.MD5.self) == md5(data))
        #expect(try await AnyArchive.hash("AM2R_11/AM2R.exe", from: archive, using: Insecure.MD5.self) == md5(Data("exe".utf8)))
        #expect(try AnyArchive.readSync("AM2R_11/odd [1].txt", from: archive, limit: 10) == Data("[x]".utf8))
        var total = 0
        try AnyArchive.stream("AM2R_11/data.win", from: archive) { total += $0.count }
        #expect(total == data.count)

        let work = root.appending(path: "work")
        try await AnyArchive.extract(["AM2R_11/data.win": work.appending(path: "data.win"),
                                      "AM2R_11/odd [1].txt": work.appending(path: "odd.txt")], from: archive)
        #expect(try Data(contentsOf: work.appending(path: "data.win")) == data)
        #expect(contents(work) == ["data.win", "odd.txt"])
        let other = root.appending(path: "other")
        #expect(throws: ArchiveError.missingEntry("AM2R_11/gone")) {
            try AnyArchive.extractSync(["AM2R_11/AM2R.exe": other.appending(path: "a"), "AM2R_11/gone": other.appending(path: "b")], from: archive)
        }
        #expect(throws: ArchiveError.unsafeEntry("../x")) { try AnyArchive.extractSync(["../x": other.appending(path: "x")], from: archive) }
        #expect(contents(other).isEmpty)
        try AnyArchive.extractSync("AM2R_11/AM2R.exe", from: archive, to: other.appending(path: "AM2R.exe"))
        #expect(readText(other.appending(path: "AM2R.exe")) == "exe")
    }

    @Test func dropsQuarantineFromAnArchiveUnpackedByTar() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("run", to: root.appending(path: "src/Game/game"))
        let archive = root.appending(path: "g.7z")
        try await Shell.run("/usr/bin/tar", ["--format", "7zip", "-cf", archive.path, "Game"], in: root.appending(path: "src")).check()
        try await Shell.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000000;Test;", archive.path]).check()
        func quarantined(_ url: URL) -> Bool { getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 }

        let kept = try await AnyArchive.unpack(archive, into: root.appending(path: "kept"))
        #expect(quarantined(kept.appending(path: "Game/game")))
        let clean = try AnyArchive.unpackSync(archive, into: root.appending(path: "clean"), dropsQuarantine: true)
        #expect(!quarantined(clean.appending(path: "Game/game")))
        #expect(!quarantined(clean.appending(path: "Game")))
    }

    @Test func anEncryptedEntryGoesThroughUnzipAndFails() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appending(path: "e.zip")
        try ZipMaker(items: [.init(name: "a.txt", data: Data("x".utf8))]).write(to: zip)
        // Set the "encrypted" flag in both headers: ArchiveKit hands it to unzip, which has no password.
        var bytes = try Data(contentsOf: zip)
        bytes[6] = 1
        let central = bytes.count - 22 - 46 - 5
        bytes[central + 8] = 1
        try bytes.write(to: zip)
        #expect(try Zip.entries(zip)[0].flags & 1 == 1)
        #expect(throws: ArchiveError.self) { try Zip.readSync("a.txt", from: zip, limit: 10) }
    }
}

@Suite struct PackOptionTests {
    @Test func filesFromSeveralFoldersSideBySide() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("log 1", to: root.appending(path: "a/game.log"))
        try writeText("log 2", to: root.appending(path: "b/deep/game.log"))
        try writeText("about", to: root.appending(path: "c/about.txt"))
        let zip = try await Zip.pack(files: [root.appending(path: "c/about.txt"), root.appending(path: "a/game.log"),
                                             root.appending(path: "b/deep/game.log"), root.appending(path: "gone.txt")],
                                     to: root.appending(path: "report.zip"))
        let entries = try Zip.entries(zip)
        #expect(Set(entries.map(\.name)) == ["about.txt", "game.log", "game 2.log"])
        #expect(try Zip.readSync("game 2.log", from: zip, limit: 10) == Data("log 2".utf8))
        let sync = try Zip.packSync(files: [root.appending(path: "c/about.txt")], to: root.appending(path: "s.zip"))
        #expect(try Zip.names(sync) == ["about.txt"])
        await #expect(throws: ArchiveError.nothingToBackUp) { try await Zip.pack(files: [root.appending(path: "gone")], to: root.appending(path: "n.zip")) }
    }

    @Test func entriesUnderTheirNamesWithoutFolderEntries() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("chip 1", to: root.appending(path: "parts/1"))
        try writeText("chip 2", to: root.appending(path: "parts/2"))
        let zip = try Zip.packSync(entries: ["mslug.p1": root.appending(path: "parts/1"), "sub/mslug.s1": root.appending(path: "parts/2")],
                                   to: root.appending(path: "mslug.zip"), level: 9, folderEntries: false)
        #expect(try Zip.names(zip).sorted() == ["mslug.p1", "sub/mslug.s1"])
        try Zip.testSync(zip)
        #expect(throws: ArchiveError.unsafeEntry("../evil")) {
            try Zip.packSync(entries: ["../evil": root.appending(path: "parts/1")], to: root.appending(path: "e.zip"))
        }
        #expect(contents(root).filter { $0.hasPrefix(".") }.isEmpty)
    }

    @Test func itemsInSubfoldersAndNoDSStore() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Emulation")
        try writeText("s1", to: folder.appending(path: "Saves/Slot 1/save"))
        try writeText("s2", to: folder.appending(path: "Saves/Slot 2/save"))
        try writeText("finder", to: folder.appending(path: "Saves/Slot 1/.DS_Store"))
        try writeText("finder", to: folder.appending(path: ".DS_Store"))
        let zip = try await Zip.pack(folder, to: root.appending(path: "i.zip"), items: ["Saves/Slot 1"], macMetadata: false)
        #expect(try fileNames(zip) == ["Saves/Slot 1/save", "Saves/Slot 1/.DS_Store"])
        let clean = try await Zip.pack(folder, to: root.appending(path: "c.zip"), dropsDSStore: true)
        #expect(try Zip.names(clean).filter { $0.hasSuffix(".DS_Store") }.isEmpty)
        #expect(try fileNames(clean) == ["Saves/Slot 1/save", "Saves/Slot 2/save"])
        let flat = try Zip.packSync(folder, to: root.appending(path: "f.zip"), keepParent: true, folderEntries: false, dropsDSStore: true)
        #expect(try Zip.names(flat).allSatisfy { !$0.hasSuffix("/") })
        #expect(Set(try Zip.names(flat).filter { !$0.hasPrefix("__MACOSX") }) == ["Emulation/Saves/Slot 1/save", "Emulation/Saves/Slot 2/save"])
    }
}

@Suite struct CancelAndTrashTests {
    @Test func aFlagSetBeforeStopsAndLeavesNothing() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("x", to: root.appending(path: "src/a.txt"))
        let flag = Shell.CancelFlag()
        flag.cancel()
        await #expect(throws: CancellationError.self) { try await Zip.pack(root.appending(path: "src"), to: root.appending(path: "a.zip"), cancel: flag) }
        #expect(throws: CancellationError.self) { try Zip.packSync(root.appending(path: "src"), to: root.appending(path: "a.zip"), cancel: flag) }
        #expect(contents(root) == ["src", "src/a.txt"])
    }

    @Test func aFlagSetDuringAStreamStopsIt() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = bigData()
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        try data.write(to: root.appending(path: "src/big"))
        let zip = root.appending(path: "b.zip")
        try Shell.runSync("/usr/bin/zip", ["-q", zip.path, "big"], in: root.appending(path: "src")).check()
        let flag = Shell.CancelFlag()
        var chunks = 0
        #expect(throws: CancellationError.self) {
            try Zip.stream("big", from: zip, cancel: flag) { _ in chunks += 1; flag.cancel() }
        }
        #expect(chunks == 1)
        let target = root.appending(path: "out/big")
        let stopped = Shell.CancelFlag()
        stopped.cancel()
        #expect(throws: CancellationError.self) { try Zip.extractSync("big", from: zip, to: target, cancel: stopped) }
        #expect(contents(root.appending(path: "out")).isEmpty)
    }

    @Test func theCallersFlagAndTheTaskBothStopRunningWork() async throws {
        let flag = Shell.CancelFlag()
        Task { try? await Task.sleep(for: .milliseconds(100)); flag.cancel() }
        await #expect(throws: CancellationError.self) {
            try await Work.run(flag) { stop in
                while !stop.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
                throw CancellationError()
            }
        }
        let task = Task {
            try await Work.run(nil) { stop in
                while !stop.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
                throw CancellationError()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // The work's own stop never sets the caller's flag.
        let untouched = Shell.CancelFlag()
        #expect(try await Work.run(untouched) { _ in 42 } == 42)
        #expect(!untouched.isCancelled)
    }

    @Test func whatIsReplacedLeavesUnderItsOwnName() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("x", to: root.appending(path: "src/a.txt"))
        let zip = root.appending(path: "out/report.zip")
        try writeText("old", to: zip)
        let bin = root.appending(path: "Bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let disposal = Disposal.custom { url in
            try FileManager.default.moveItem(at: url, to: bin.appending(path: url.lastPathComponent))
        }
        try await Zip.pack(root.appending(path: "src"), to: zip, replacing: true, replaced: disposal)
        #expect(contents(bin) == ["report.zip"])
        #expect(readText(bin.appending(path: "report.zip")) == "old")
        #expect(contents(root.appending(path: "out")) == ["report.zip"])

        try FileManager.default.createDirectory(at: root.appending(path: "dest/Game"), withIntermediateDirectories: true)
        try await Zip.unpack(zip, into: root.appending(path: "dest/Game"), replacing: true, replaced: disposal)
        #expect(contents(bin) == ["Game", "report.zip"])
        #expect(contents(root.appending(path: "dest")) == ["Game", "Game/a.txt"])
    }

    @Test func aDisposalThatFailsLeavesTheOldOneHidden() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("x", to: root.appending(path: "src/a.txt"))
        let zip = root.appending(path: "out/r.zip")
        try writeText("old", to: zip)
        try await Zip.pack(root.appending(path: "src"), to: zip, replacing: true, replaced: .custom { _ in throw CocoaError(.fileWriteNoPermission) })
        let hidden = contents(root.appending(path: "out")).filter { $0.hasPrefix(".") }
        #expect(hidden.count == 2 && hidden.contains { $0.hasSuffix("/r.zip") })
    }
}

@Suite struct BackupOptionTests {
    @Test func theDateGivenIsTheBackupsDateWithAName() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("s", to: root.appending(path: "saves/save1"))
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_760_000_000)
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .delete)
        try await store.backUp(from: root.appending(path: "saves"), name: "Newer", date: newer)
        let old = try await store.backUp(from: root.appending(path: "saves"), name: "Older", date: older)
        #expect(old.date == older)
        #expect(store.list().map(\.name) == ["Newer", "Older"])

        // Touched later (copied, synced): the creation date keeps the order.
        try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: old.url.path)
        #expect(store.list().map(\.name) == ["Older", "Newer"])
        let created = BackupFolder(root: root.appending(path: "B"), disposal: .delete, dating: .created)
        #expect(created.list().map(\.name) == ["Newer", "Older"])
        #expect(created.list().last?.date == older)
    }

    @Test func restoreKeepingTheZipsTopFolder() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let saves = root.appending(path: "Saves")
        try writeText("v1", to: saves.appending(path: "Mats_391030616/SaveGameInfo"))
        try writeText("other", to: saves.appending(path: "Lae_1/SaveGameInfo"))
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .delete)
        let backup = try await store.backUp(from: saves.appending(path: "Mats_391030616"), keepParent: true, name: "Mats_391030616 2026-11-25 101010")
        try writeText("v2", to: saves.appending(path: "Mats_391030616/SaveGameInfo"))
        try writeText("new", to: saves.appending(path: "Mats_391030616/extra"))

        try await store.restore(backup, into: saves, keepsTopFolder: true, accept: { top in
            FileManager.default.fileExists(atPath: top.appending(path: "Mats_391030616/SaveGameInfo").path)
        })
        #expect(readText(saves.appending(path: "Mats_391030616/SaveGameInfo")) == "v1")
        #expect(!FileManager.default.fileExists(atPath: saves.appending(path: "Mats_391030616/extra").path))
        #expect(readText(saves.appending(path: "Lae_1/SaveGameInfo")) == "other")
        #expect(contents(saves).filter { $0.hasPrefix(".") }.isEmpty)

        await #expect(throws: ArchiveError.notABackup) {
            try await store.restore(backup, into: saves, keepsTopFolder: true, accept: { _ in false })
        }
    }
}

@Suite struct MessageTests {
    @Test func everyErrorSpeaksEnglishAndFrench() {
        let all: [ArchiveError] = [.notAZip(size: 0), .notAZip(size: 9), .damaged("too short"), .unsafeEntry("../x"), .tooLarge,
                                   .missingEntry("data.win"), .exists(URL(fileURLWithPath: "/tmp/Game")), .nothingToBackUp, .notABackup]
        for error in all {
            #expect(error.message(language: "en") != error.message(language: "fr"))
            #expect(error.message(language: "fr-CA") == error.message(language: "fr"))
            #expect(!error.message(language: "fr").isEmpty)
        }
        #expect(ArchiveError.tooLarge.errorDescription == "This archive is too large.")
        #expect(ArchiveError.missingEntry("data.win").message(language: "fr") == "«\u{00A0}data.win\u{00A0}» ne se trouve pas dans cette archive.")
        #expect(ArchiveError.nothingToBackUp.message(language: "fr") == "Il n’y a rien à sauvegarder.")
        #expect(ArchiveError.toolFailed("tar: boom").message(language: "fr") == "tar: boom")
    }
}
