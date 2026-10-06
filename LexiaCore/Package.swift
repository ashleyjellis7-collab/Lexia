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
            resources: [.copy("Resources/words_en.txt")],
            // The spelling engine runs on every keystroke, so keep it optimised
            // even in Debug builds (keyboard extensions are run from Xcode in Debug).
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(
            name: "LexiaCoreTests",
            dependencies: ["LexiaCore"]
        ),
    ]
)
