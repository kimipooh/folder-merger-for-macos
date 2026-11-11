// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FolderMergerCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "FolderMergerCore", targets: ["FolderMergerCore"])],
    targets: [
        .target(name: "FolderMergerCore"),
        .testTarget(name: "FolderMergerCoreTests", dependencies: ["FolderMergerCore"])
    ]
)
