// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "agents-sdk-swift",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "Agents", targets: ["Agents"]),
        .library(name: "AgentsChat", targets: ["AgentsChat"]),
        .executable(name: "E2ESmoke", targets: ["E2ESmoke"]),
    ],
    targets: [
        .target(
            name: "Agents"
            // If strict Swift 6 concurrency proves too costly during the build phases,
            // relax this target to the Swift 5 language mode here, e.g.:
            // swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AgentsChat",
            dependencies: ["Agents"]
            // See note above re: .swiftLanguageMode(.v5) if needed.
        ),
        .executableTarget(
            name: "E2ESmoke",
            dependencies: ["Agents", "AgentsChat"]
        ),
        .testTarget(
            name: "AgentsTests",
            dependencies: ["Agents"]
        ),
        .testTarget(
            name: "AgentsChatTests",
            dependencies: ["AgentsChat"]
        ),
    ]
)
