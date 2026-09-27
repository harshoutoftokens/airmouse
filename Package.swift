// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirTrackpad",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AirTrackpadCore",
            targets: ["AirTrackpadCore"]
        ),
        .executable(
            name: "AirTrackpad",
            targets: ["AirTrackpadApp"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AirTrackpadCore",
            dependencies: [],
            path: "Sources/AirTrackpadCore"
        ),
        .executableTarget(
            name: "AirTrackpadApp",
            dependencies: ["AirTrackpadCore"],
            path: "Sources/AirTrackpadApp"
        ),
        .testTarget(
            name: "AirTrackpadTests",
            dependencies: ["AirTrackpadCore"],
            path: "Tests/AirTrackpadTests"
        )
    ]
)
