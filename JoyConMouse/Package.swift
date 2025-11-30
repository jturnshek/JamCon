// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JoyConMouse",
    platforms: [
        .macOS(.v14)  // macOS 14 Sonoma minimum (update to v15/v26 when available)
    ],
    products: [
        .executable(name: "JoyConMouse", targets: ["JoyConMouse"])
    ],
    dependencies: [
        .package(path: "Packages/JoyConSwift")
    ],
    targets: [
        .executableTarget(
            name: "JoyConMouse",
            dependencies: ["JoyConSwift"],
            path: "Sources/JoyConMouse"
        )
    ]
)
