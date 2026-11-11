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
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3"),
    ],
    targets: [
        .executableTarget(
            name: "TextTap",
            dependencies: ["WhisperKit", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/TextTap"
        ),
        .testTarget(
            name: "TextTapTests",
            dependencies: [ "TextTap" ]
        ),
    ]
)
