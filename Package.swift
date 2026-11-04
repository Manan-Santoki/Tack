// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ClipHistory",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ClipHistory",
            path: "Sources/ClipHistory"
        ),
        .testTarget(
            name: "ClipHistoryTests",
            dependencies: ["ClipHistory"],
            path: "Tests/ClipHistoryTests"
        ),
    ]
)
