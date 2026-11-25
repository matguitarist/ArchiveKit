import Foundation
import Testing
@testable import ArchiveKit

@Suite struct BackupFolderTests {
    func saves(_ root: URL) throws -> URL {
        let folder = root.appending(path: "saves", directoryHint: .isDirectory)
        try writeText("slot 1", to: folder.appending(path: "save1"))
        try writeText("ini", to: folder.appending(path: "config.ini"))
        return folder
    }

    @Test func backsUpWithADateStampAndALabel() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupFolder(root: root.appending(path: "Backups"), disposal: .delete)
        let date = Date(timeIntervalSince1970: 1_764_000_000)
        let first = try await store.backUp(from: try saves(root), label: "Before restore", date: date)
        let second = try await store.backUp(from: try saves(root), label: "Before restore", date: date)
        #expect(first.name == BackupFolder.stamp(date) + " - Before restore")
        #expect(second.name == BackupFolder.stamp(date) + " - Before restore 2")
        #expect(second.label == "Before restore")
        #expect(first.size > 0)
        #expect(try fileNames(first.url) == ["save1", "config.ini"])
        #expect(store.list().map(\.name) == [second.name, first.name])
    }

    @Test func aNameOfTheAppsOwn() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .delete)
        let backup = try await store.backUp(from: try saves(root), keepParent: true, name: "Mats_391030616 2026-11-24 140509", macMetadata: false)
        #expect(backup.name == "Mats_391030616 2026-11-24 140509")
        #expect(backup.label == nil)
        #expect(Zip.topLevelNames(try Zip.entries(backup.url)) == ["saves"])
        let slashed = try await store.backUp(from: try saves(root), label: "a/b:c")
        #expect(slashed.label == "a-b-c")
    }

    @Test func itemsAndNothingToBackUp() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .delete)
        let folder = try saves(root)
        let backup = try await store.backUp(from: folder, items: ["save1", "missing"])
        #expect(try fileNames(backup.url) == ["save1"])
        await #expect(throws: ArchiveError.nothingToBackUp) { try await store.backUp(from: folder, items: ["missing"]) }
        let empty = root.appending(path: "empty")
        try writeText("", to: empty.appending(path: ".DS_Store"))
        await #expect(throws: ArchiveError.nothingToBackUp) { try await store.backUp(from: empty) }
        await #expect(throws: ArchiveError.nothingToBackUp) { try await store.backUp(from: root.appending(path: "nowhere")) }
    }

    @Test func restoresAWholeFolder() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .delete)
        let folder = try saves(root)
        let backup = try await store.backUp(from: folder)
        try writeText("slot 1 later", to: folder.appending(path: "save1"))
        try writeText("new", to: folder.appending(path: "save2"))
        try await store.restore(backup, into: folder)
        #expect(contents(folder) == ["config.ini", "save1"])
        #expect(readText(folder.appending(path: "save1")) == "slot 1")
        #expect(contents(root).allSatisfy { !$0.split(separator: "/").contains { $0.hasPrefix(".") } })
    }

    @Test func aZippedFolderRestoresItsContent() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .delete)
        let folder = try saves(root)
        let backup = try await store.backUp(from: folder, keepParent: true)
        try FileManager.default.removeItem(at: folder)
        try await store.restore(backup, into: folder)
        #expect(contents(folder) == ["config.ini", "save1"])
    }

    @Test func acceptDecidesWhatTheContentIs() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .delete)
        // A backup whose top holds one folder that is itself part of the saves.
        let source = root.appending(path: "source")
        try writeText("srm", to: source.appending(path: "profile/save.srm"))
        let backup = try await store.backUp(from: source)
        let isSaves: @Sendable (URL) -> Bool = { folder in
            FileManager.default.fileExists(atPath: folder.appending(path: "save.srm").path)
        }
        let target = root.appending(path: "target")
        try await store.restore(backup, into: target, accept: isSaves)
        #expect(contents(target) == ["save.srm"])

        // Not a backup of these files: refused, the folder untouched.
        let other = root.appending(path: "other")
        try writeText("keep", to: other.appending(path: "keep.txt"))
        let foreign = try await store.backUp(from: try saves(root))
        await #expect(throws: ArchiveError.notABackup) { try await store.restore(foreign, into: other, accept: isSaves) }
        #expect(contents(other) == ["keep.txt"])
    }

    @Test func restoresChosenItemsAndKeepsTheRest() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let disposed = Recorder()
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .custom { url in
            disposed.add(url)
            try FileManager.default.removeItem(at: url)
        })
        let savesFolder = root.appending(path: "Saves")
        try writeText("farm A", to: savesFolder.appending(path: "A_1/SaveGameInfo"))
        try writeText("farm B", to: savesFolder.appending(path: "B_2/SaveGameInfo"))
        let backup = try await store.backUp(from: savesFolder, items: ["A_1", "B_2"])
        try writeText("farm A later", to: savesFolder.appending(path: "A_1/SaveGameInfo"))
        try writeText("farm B later", to: savesFolder.appending(path: "B_2/SaveGameInfo"))
        try await store.restore(backup, into: savesFolder, items: ["A_1"])
        #expect(readText(savesFolder.appending(path: "A_1/SaveGameInfo")) == "farm A")
        #expect(readText(savesFolder.appending(path: "B_2/SaveGameInfo")) == "farm B later")
        #expect(disposed.urls.count == 1)
        await #expect(throws: ArchiveError.notABackup) { try await store.restore(backup, into: savesFolder, items: ["C_3"]) }
    }

    @Test func aDamagedBackupChangesNothing() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .delete)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let bad = store.root.appending(path: "bad.zip")
        try writeText("PK not really", to: bad)
        let folder = try saves(root)
        await #expect(throws: ArchiveError.notABackup) { try await store.restore(try store.backup(at: bad), into: folder) }
        #expect(contents(folder) == ["config.ini", "save1"])
        #expect(contents(root).allSatisfy { !$0.hasPrefix(".") })
    }

    @Test func anUnsafeBackupIsRefused() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .delete)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        var maker = ZipMaker()
        maker.file("../../escape.txt", "evil")
        let zip = store.root.appending(path: "evil.zip")
        try maker.write(to: zip)
        let folder = try saves(root)
        await #expect(throws: ArchiveError.unsafeEntry("../../escape.txt")) { try await store.restore(try store.backup(at: zip), into: folder) }
        #expect(contents(folder) == ["config.ini", "save1"])
    }

    @Test func prunesTheOldestMatching() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupFolder(root: root.appending(path: "B"), disposal: .delete)
        let folder = try saves(root)
        var autos: [BackupFolder.Backup] = []
        for _ in 0..<4 { autos.append(try await store.backUp(from: folder, label: "Auto")) }
        let manual = try await store.backUp(from: folder, label: "By hand")
        let removed = try store.prune(keep: 2, matching: { $0.label == "Auto" })
        #expect(Set(removed.map(\.url)) == Set(autos.prefix(2).map(\.url)))
        #expect(Set(store.list().map(\.url)) == Set([manual.url] + autos.suffix(2).map(\.url)))
        try store.delete(manual)
        #expect(store.list().count == 2)
        try store.prune(keep: 0)
        #expect(store.list().isEmpty)
    }

    @Test func sameSecondTwinsSortByTheirNumber() {
        let date = Date()
        func backup(_ name: String) -> BackupFolder.Backup {
            .init(url: URL(fileURLWithPath: "/b/\(name).zip"), date: date, size: 0)
        }
        let sorted = [backup("x - Auto"), backup("x - Auto 3"), backup("x - Auto 2")].sorted(by: BackupFolder.newerFirst)
        #expect(sorted.map(\.name) == ["x - Auto 3", "x - Auto 2", "x - Auto"])
    }
}
