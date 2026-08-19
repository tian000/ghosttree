// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ghosttree",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GhosttreeCore", targets: ["GhosttreeCore"]),
        .executable(name: "ghosttree", targets: ["ghosttree"]),
    ],
    targets: [
        .target(name: "GhosttreeCore"),
        .executableTarget(name: "ghosttree", dependencies: ["GhosttreeCore"]),
        .testTarget(name: "GhosttreeCoreTests", dependencies: ["GhosttreeCore"]),
    ]
)
