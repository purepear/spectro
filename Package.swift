// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spectro",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "Spectro",
            targets: ["SpectroApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "SpectroApp",
            path: "Sources/SpectroApp"
        ),
        .testTarget(
            name: "SpectroAppTests",
            dependencies: ["SpectroApp"],
            path: "Tests/SpectroAppTests"
        )
    ]
)
