// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JoyConSwift",
    platforms: [
        .macOS(.v10_13)
    ],
    products: [
        .library(
            name: "JoyConSwift",
            targets: ["JoyConSwift"]
        )
    ],
    targets: [
        .target(
            name: "JoyConSwift",
            path: "Source",
            exclude: ["Info.plist", "JoyConSwift.h"],
            sources: [
                "Controller.swift",
                "HomeLEDPattern.swift",
                "JoyCon.swift",
                "JoyConManager.swift",
                "Rumble.swift",
                "Subcommand.swift",
                "Utils.swift",
                "controllers/FamicomController1.swift",
                "controllers/FamicomController2.swift",
                "controllers/JoyConL.swift",
                "controllers/JoyConR.swift",
                "controllers/ProController.swift",
                "controllers/SNESController.swift"
            ]
        )
    ]
)
