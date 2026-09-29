// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexProviderSwitcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "CodexProviderSwitcher",
            targets: ["CodexProviderSwitcher"]
        )
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3"
        ),
        .executableTarget(
            name: "CodexProviderSwitcher",
            dependencies: ["CSQLite"]
        )
    ]
)
