// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClaudeDesk", targets: ["ClaudeDesk"])],
    targets: [
        .target(name: "SwiftTerm", path: "Vendor/SwiftTerm/Sources/SwiftTerm",
                exclude: ["iOS", "Mac/README.md"],
                resources: [.process("Apple/Metal/Shaders.metal")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ClaudeDesk", dependencies: ["SwiftTerm"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ClaudeDeskTests", dependencies: ["ClaudeDesk"])
    ]
)
