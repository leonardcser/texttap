// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TextTap",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TextTap", targets: ["TextTap"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "TextTap",
            dependencies: ["WhisperKit"],
            path: "Sources/TextTap"
        )
    ]
)
