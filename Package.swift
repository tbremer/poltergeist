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
        .package(url: "https://github.com/lakr233/libghostty-spm", exact: "1.2.5"),
        // User-customizable global hotkeys (Carbon-backed, no Accessibility prompt).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.0")
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
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                "CPty"
            ],
            path: "Sources/Poltergeist"
        )
    ]
)
