# ArchiveKit

How my Mac apps unpack, pack and back up archives without ever writing outside a folder or leaving a half-written
one. It gathers what each app wrote on its own: RenChan's `ZipImport` (Zip Slip checks), Kamiro's staging folder
beside the target, the launchers' restores swapped in only when whole, Starseed's and Attic's zipped backups kept
to the newest few, SMLauncher Plus's reads of one ROM out of a zip or a 7z.

- **Zip**: entries read from the zip's own directory (ZIP64 too, symbolic links and their targets), the Zip Slip
  check, unpacking into a hidden folder beside the target and moving it into place, packing with ditto (macOS
  metadata kept, or a plain zip), reading or extracting one entry, a CRC test.
- **AnyArchive**: 7z, RAR, tar and the rest through macOS's own tar, with the same checks.
- **BackupFolder**: a folder of dated zips: back up, list, restore, prune, delete.
- **UniqueName**: "name", then "name 2", "name 3".

macOS 14 or later. Mac only: it runs ditto, unzip and tar through [ProcessKit](https://github.com/matguitarist/ProcessKit).

## Add it to an app

SwiftPM (`Package.swift`):

```swift
.package(url: "https://github.com/matguitarist/ArchiveKit", from: "0.1.0"),
// in the target that handles archives:
.product(name: "ArchiveKit", package: "ArchiveKit"),
```

XcodeGen (`project.yml`):

```yaml
packages:
  ArchiveKit:
    url: https://github.com/matguitarist/ArchiveKit
    from: 0.1.0
targets:
  App:
    dependencies:
      - package: ArchiveKit
```

ProcessKit comes with it.

## Unpack a zip

```swift
import ArchiveKit

// Before asking: what's in it, how big, is it safe.
let entries = try Zip.entries(zip)                    // ArchiveError.notAZip(size:) for a web page saved as .zip
let size = try Zip.uncompressedSize(zip)
if let bad = Zip.unsafeEntry(entries) { show(bad) }

// Checked, unpacked beside the target, moved into place when whole. A refusal, a failure or a cancel writes nothing.
try await Zip.unpack(zip, into: library.appending(path: "Game 1.0"), dropsQuarantine: true)

// Over a folder that's there: the old one goes to the Trash (or .delete, or .custom) once the new one is in place.
try await Zip.unpack(zip, into: saves, replacing: true, replaced: .delete)

// A mod from the internet: refuse anything over 256 MB or 4096 files before writing a byte.
try await Zip.unpack(mod, into: staging, maxBytes: 256 << 20, maxEntries: 4096)

// Then: the folder inside when the zip held one folder.
let content = Zip.contentFolder(unpacked)
```

Refused, with nothing written (`ArchiveError.unsafeEntry(name)`): absolute paths (`/`, `\\`), drive letters
(`C:`), any `..` part, a symbolic link pointing out of the folder, and any entry inside a symbolic link (a link to a
folder, then a file written through it). After unpacking, every link is checked again.

ditto doesn't check CRCs; call `try await Zip.test(zip)` first when a damaged download must be caught.

## One entry, without unpacking

```swift
let rom = try await Zip.read("Super Metroid (JU) [!].sfc", from: zip, limit: 8 << 20)   // .tooLarge past the limit
try await Zip.extract("Mod/data.win", from: zip, to: game.appending(path: "data.win"))   // streams to the file
let info = try await AnyArchive.read("Mats_391030616/SaveGameInfo", from: sevenZip, limit: 1 << 20)
```

Names with `[ ] * ?` are read exactly, not as patterns.

## Pack

```swift
// The folder's content at the top of the zip, written beside it and moved into place.
try await Zip.pack(saves, to: backupZip)
// The folder itself at the top, like the Finder's Compress.
try await Zip.pack(saveFolder, to: zip, keepParent: true)
// Some items of a folder, a plain zip without macOS metadata, best compression.
try await Zip.pack(emulation, to: zip, items: ["Saves", "States"], macMetadata: false, level: 9)
```

## Other archives

```swift
let names = try await AnyArchive.names(rar)
try await AnyArchive.unpack(sevenZip, into: work)
```

## Backups

```swift
let backups = BackupFolder(root: appSupport.appending(path: "SaveBackups"))   // disposal: .trash by default

// "2026-11-24 14.05.09 - Before restore.zip"; " 2" when one was made the same second.
try await backups.backUp(from: saves, label: "Before restore")
// Your own name, some items only, the folder itself at the top, a plain zip.
try await backups.backUp(from: savesFolder, items: ["Mats_391030616"], name: "\(profile) \(stamp)", macMetadata: false)

let list = backups.list()                  // newest first: url, name, label, date, size
try await backups.restore(list[0], into: saves, accept: { $0.appending(path: "config.ini").isFile })
try await backups.restore(list[0], into: savesFolder, items: ["Mats_391030616"])   // the others stay
try backups.prune(keep: 5, matching: { $0.label == "Auto" })
try backups.delete(list[0])
```

A restore unpacks beside the folder, checks it (`accept`, the app's own test that the content is its files), and
swaps it in; the replaced folder or items go to `disposal`. Nothing changes when the zip is damaged, unsafe or not
accepted (`ArchiveError.notABackup`). Make a "Before restore" backup first when the current files matter.

## Unique names

```swift
UniqueName.url(for: "Archive.zip", in: folder)     // Archive.zip, Archive 2.zip, Archive 3.zip…
UniqueName.name(for: "My.Project", in: folder, isFolder: true)
```

## Errors

`ArchiveError`: `notAZip(size:)`, `damaged`, `unsafeEntry`, `tooLarge`, `missingEntry`, `exists`,
`nothingToBackUp`, `notABackup`, `toolFailed` (the tool's last words). Each has a sentence in
`localizedDescription`. Cancelling the task stops the tool and throws `CancellationError`, with nothing left behind.
