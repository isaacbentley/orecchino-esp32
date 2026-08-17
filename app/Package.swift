// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Orecchino",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Orecchino",
            path: "Sources/Orecchino"
        ),
        .testTarget(
            name: "OrecchinoTests",
            dependencies: ["Orecchino"],
            path: "Tests/OrecchinoTests"
        )
    ]
)
