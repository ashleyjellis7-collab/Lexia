// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LexiaCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LexiaCore", targets: ["LexiaCore"]),
    ],
    targets: [
        .target(
            name: "LexiaCore",
            resources: [.copy("Resources/words_en.txt")]
        ),
        .testTarget(
            name: "LexiaCoreTests",
            dependencies: ["LexiaCore"]
        ),
    ]
)
