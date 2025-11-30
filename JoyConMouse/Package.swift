// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JamCon",
    platforms: [
        .macOS(.v14)  // macOS 14 Sonoma minimum (update to v15/v26 when available)
    ],
    products: [
        .executable(name: "JamCon", targets: ["JamCon"])
    ],
    dependencies: [
        .package(path: "Packages/JoyConSwift")
    ],
    targets: [
        .executableTarget(
            name: "JamCon",
            dependencies: ["JoyConSwift"],
            path: "Sources/JamCon",
            resources: [
                .copy("Resources/joyconL.png"),
                .copy("Resources/joyconR.png"),
                .copy("Resources/joycon.png")
            ]
        )
    ]
)
