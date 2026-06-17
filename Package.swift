// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Poltergeist",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // GhosttyKit (libghostty Swift Package). Pinned for reproducibility.
        // Products: GhosttyKit, GhosttyTerminal, ShellCraftKit, GhosttyTheme
        .package(url: "https://github.com/lakr233/libghostty-spm", exact: "1.2.5")
    ],
    targets: [
        .executableTarget(
            name: "Poltergeist",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm")
            ],
            path: "Sources/Poltergeist"
        )
    ]
)
