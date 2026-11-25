# ArchiveKit

How my Mac apps unpack, pack and back up archives: Zip Slip checks before anything is written, work in a hidden
folder beside the target moved into place when whole, dated zip backups. Shared by RenChan, Kamiro, Starseed,
AM2R Launcher Plus, SMLauncher Plus, Tadpole, Attic and Hangar, and the next ones. Built on ProcessKit. A change
here reaches every app at its next package update, so keep the API stable and additive.

Shared rules for how every project is laid out and named:
@~/.claude/project-layout.md

## Layout

- `Sources/ArchiveKit/` Foundation only, macOS only (ditto, unzip, tar through ProcessKit):
  - `Zip.swift`: `isZip`, `entries`, `names`, `uncompressedSize`, `unsafeEntry`, `topLevelNames`, `unpack`,
    `contentFolder`, `read`, `extract`, `test`, `pack`.
  - `ZipDirectory.swift`: the central directory reader (ZIP64, symbolic links and their targets).
  - `Safety.swift`: the Zip Slip rules, before and after unpacking.
  - `AnyArchive.swift`: 7z, RAR, tar through bsdtar.
  - `BackupFolder.swift`, `UniqueName.swift`, `Staging.swift` (hidden folders beside the target, the swap,
    `Disposal`), `ArchiveError.swift`.
- `Tests/ArchiveKitTests/` Swift Testing. Zips are made in code (`ZipMaker` writes the malicious ones no tool
  would), with ditto, zip and tar; no fixture files.

## Rules

- Check every entry before writing anything; check the links again after unpacking. A refusal writes nothing.
- Unpack, pack and restore beside the target, on the same disk, and move into place only when whole. On any error or
  cancel, remove the work folder.
- What a swap replaces goes to the caller's `Disposal` only after the new one is in place; never delete what the
  person owns without being asked.
- Everything is safe from any thread and does no I/O on the main thread by itself.
- Temp files in tests only under `FileManager.default.temporaryDirectory`. Tests use `.delete` or `.custom`,
  never the real Trash.
- Add a test for every change, and a malicious zip for every new rule. `swift build && swift test` pass with no
  warnings, then CI on macOS.
- Release: tag `x.y.z` and push the tag; apps use `from:`.

## Git

Commit after each working change, with a message that says what an app can now do.
