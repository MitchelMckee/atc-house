// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ATCHouse",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources are copied into the .app by build.sh, not via SwiftPM.
        .executableTarget(name: "ATCHouse", exclude: ["Resources"])
    ]
)
