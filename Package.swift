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
        // Tiny C shim for pty primitives Swift can't reach directly:
        // forkpty(), and ioctl(TIOCSWINSZ) whose request macro is opaque to Swift.
        .target(
            name: "CPty",
            path: "Sources/CPty"
        ),
        .executableTarget(
            name: "Poltergeist",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                "CPty"
            ],
            path: "Sources/Poltergeist"
        )
    ]
)
