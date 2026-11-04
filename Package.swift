// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tack",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Tack",
            path: "Sources/Tack"
        ),
        .testTarget(
            name: "TackTests",
            dependencies: ["Tack"],
            path: "Tests/TackTests"
        ),
    ]
)
