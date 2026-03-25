// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FocusShield",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.2.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "FocusShield",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources",
            exclude: ["iOS", "DNSProxy"]
        ),
        .executableTarget(
            name: "FocusShieldDNS",
            path: "Sources/DNSProxy"
        )
    ]
)
