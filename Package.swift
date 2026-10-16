// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WeGit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "WeGitCore", targets: ["WeGitCore"]),
        .executable(name: "WeGitAskPass", targets: ["WeGitAskPass"]),
        .executable(name: "WeGitBenchmarks", targets: ["WeGitBenchmarks"]),
    ],
    targets: [
        .target(name: "WeGitCore", path: "WeGitCore", resources: [.process("Resources")]),
        .executableTarget(name: "WeGitAskPass", dependencies: ["WeGitCore"], path: "WeGitAskPass"),
        .executableTarget(name: "WeGitBenchmarks", dependencies: ["WeGitCore"], path: "Benchmarks"),
        .testTarget(name: "WeGitCoreTests", dependencies: ["WeGitCore", "WeGitAskPass"], path: "WeGitTests"),
    ]
)
