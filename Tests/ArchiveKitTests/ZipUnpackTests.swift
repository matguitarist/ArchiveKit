import Foundation
import Testing
@testable import ArchiveKit

@Suite struct ZipUnpackTests {
    /// Unpacking `zip` into root/out must fail with `.unsafeEntry` and write nothing at all.
    func expectRefused(_ maker: ZipMaker, file: String = #filePath, line: Int = #line) async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appending(path: "evil.zip")
        try maker.write(to: zip)
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let out = work.appending(path: "out", directoryHint: .isDirectory)
        do {
            try await Zip.unpack(zip, into: out)
            Issue.record("unpacked an unsafe zip")
        } catch let error as ArchiveError {
            guard case .unsafeEntry = error else { Issue.record("\(error)"); return }
        }
        #expect(contents(work).isEmpty, "something was written: \(contents(work))")
        #expect(contents(root) == ["evil.zip", "work"])
    }

    @Test func refusesDotDot() async throws {
        var maker = ZipMaker()
        maker.file("ok.txt", "fine")
        maker.file("../escaped.txt", "evil")
        try await expectRefused(maker)
    }

    @Test func refusesDeepDotDot() async throws {
        var maker = ZipMaker()
        maker.file("a/b/../../../escaped.txt", "evil")
        try await expectRefused(maker)
    }

    @Test func refusesAbsolutePaths() async throws {
        var maker = ZipMaker()
        maker.file("/tmp/archivekit-absolute-\(UUID().uuidString).txt", "evil")
        try await expectRefused(maker)
    }

    @Test func refusesALinkPointingOut() async throws {
        var maker = ZipMaker()
        maker.link("docs", to: "/tmp")
        try await expectRefused(maker)
    }

    @Test func refusesALinkClimbingOut() async throws {
        var maker = ZipMaker()
        maker.link("a/up", to: "../../..")
        try await expectRefused(maker)
    }

    @Test func refusesAFileWrittenThroughALink() async throws {
        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: outside) }
        var maker = ZipMaker()
        maker.link("through", to: outside.path)
        maker.file("through/planted.txt", "evil")
        try await expectRefused(maker)
        #expect(contents(outside).isEmpty)
    }

    @Test func unpacksIntoANewFolder() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var maker = ZipMaker()
        maker.folder("Game/")
        maker.file("Game/game/script.rpy", "label start:")
        maker.link("Game/lib/current", to: "../game/script.rpy")
        let zip = root.appending(path: "game.zip")
        try maker.write(to: zip)
        let out = root.appending(path: "Library/Game 1.0", directoryHint: .isDirectory)
        let made = try await Zip.unpack(zip, into: out)
        #expect(made == out)
        #expect(readText(out.appending(path: "Game/game/script.rpy")) == "label start:")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.appending(path: "Game/lib/current").path) == "../game/script.rpy")
        #expect(contents(root.appending(path: "Library")).allSatisfy { !$0.hasPrefix(".") })
        #expect(Zip.contentFolder(out) == out.appending(path: "Game", directoryHint: .isDirectory))
    }

    @Test func anExistingFolderIsLeftAloneUnlessReplacing() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var maker = ZipMaker()
        maker.file("new.txt", "new")
        let zip = root.appending(path: "n.zip")
        try maker.write(to: zip)
        let out = root.appending(path: "out")
        try writeText("old", to: out.appending(path: "old.txt"))

        await #expect(throws: ArchiveError.exists(out)) { try await Zip.unpack(zip, into: out) }
        #expect(readText(out.appending(path: "old.txt")) == "old")

        let disposed = Recorder()
        try await Zip.unpack(zip, into: out, replacing: true, replaced: .custom { url in
            disposed.add(url)
            try FileManager.default.removeItem(at: url)
        })
        #expect(contents(out) == ["new.txt"])
        #expect(disposed.urls.count == 1)
        #expect(contents(root).sorted() == ["n.zip", "out", "out/new.txt"])
    }

    @Test func aDamagedZipLeavesNothingAndTheOldFolderStays() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var maker = ZipMaker()
        maker.items.append(.init(name: "broken.txt", data: Data("data".utf8), badCRC: true))
        let zip = root.appending(path: "bad.zip")
        try maker.write(to: zip)
        // Its directory reads well, but its first local header is gone.
        var bytes = try Data(contentsOf: zip)
        bytes[0] = 0x50; bytes[1] = 0x4B; bytes[2] = 0x03; bytes[3] = 0x04
        bytes.replaceSubrange(4..<30, with: Data(repeating: 0xFF, count: 26))
        try bytes.write(to: zip)
        let out = root.appending(path: "out")
        try writeText("keep me", to: out.appending(path: "old.txt"))
        await #expect(throws: ArchiveError.self) { try await Zip.unpack(zip, into: out, replacing: true, replaced: .delete) }
        #expect(contents(out) == ["old.txt"])
        #expect(contents(root).sorted() == ["bad.zip", "out", "out/old.txt"])
        await #expect(throws: ArchiveError.self) { try await Zip.test(zip) }
    }

    @Test func limitsRefuseBeforeWriting() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var maker = ZipMaker()
        maker.file("a", String(repeating: "a", count: 100))
        maker.file("b", "b")
        let zip = root.appending(path: "l.zip")
        try maker.write(to: zip)
        await #expect(throws: ArchiveError.tooLarge) { try await Zip.unpack(zip, into: root.appending(path: "x"), maxBytes: 50) }
        await #expect(throws: ArchiveError.tooLarge) { try await Zip.unpack(zip, into: root.appending(path: "x"), maxEntries: 1) }
        #expect(contents(root) == ["l.zip"])
        try await Zip.unpack(zip, into: root.appending(path: "x"), maxBytes: 101, maxEntries: 2)
    }

    @Test func notAZipWritesNothing() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "game.zip")
        try writeText(String(repeating: "<html>", count: 3), to: file)
        await #expect(throws: ArchiveError.notAZip(size: 18)) { try await Zip.unpack(file, into: root.appending(path: "out")) }
        #expect(contents(root) == ["game.zip"])
    }

    @Test func cancellingLeavesNothing() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Enough random bytes that ditto takes a moment.
        var bytes = [UInt8](repeating: 0, count: 64 << 20)
        for index in stride(from: 0, to: bytes.count, by: 8) { bytes[index] = UInt8.random(in: 0...255) }
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        try Data(bytes).write(to: root.appending(path: "src/big.bin"))
        let zip = root.appending(path: "big.zip")
        try await Zip.pack(root.appending(path: "src"), to: zip, level: 0)
        let out = root.appending(path: "out")
        let task = Task { try await Zip.unpack(zip, into: out) }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        _ = try? await task.value
        // Either it finished before the cancel, or nothing is left.
        let left = contents(root).filter { !$0.hasPrefix("src") && $0 != "big.zip" }
        #expect(left.isEmpty || left == ["out", "out/big.bin"])
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func add(_ url: URL) { lock.withLock { stored.append(url) } }
    var urls: [URL] { lock.withLock { stored } }
}
