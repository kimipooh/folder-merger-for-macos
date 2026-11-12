// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FolderMergerCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.library(name: "FolderMergerCore", targets: ["FolderMergerCore"])],
    targets: [
        .target(name: "FolderMergerCore", resources: [.process("Resources")]),
        .testTarget(name: "FolderMergerCoreTests", dependencies: ["FolderMergerCore"])
    ]
)
