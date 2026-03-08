// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockPeek",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DockPeek",
            path: "Sources/DockPeek",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
