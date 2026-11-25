// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArchiveKit",
    // Mac only: it unpacks and packs with ditto, unzip and tar through ProcessKit.
    platforms: [.macOS(.v14)],
    products: [
        // Zip with Zip Slip checks and staging, other archives through tar, save backups. No SwiftUI.
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/matguitarist/ProcessKit", from: "0.1.1"),
    ],
    targets: [
        .target(name: "ArchiveKit", dependencies: [.product(name: "ProcessKit", package: "ProcessKit")]),
        .testTarget(name: "ArchiveKitTests", dependencies: ["ArchiveKit"]),
    ]
)
