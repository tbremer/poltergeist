<p align="center">
  <img src="icon/AppIcon.png" width="160" height="160" alt="Poltergeist icon">
</p>

<h1 align="center">Poltergeist</h1>

<p align="center">A macOS terminal that's aware of OpenCode.</p>

Poltergeist is a single-window macOS terminal emulator built on [Ghostty](https://github.com/ghostty-org/ghostty)'s `libghostty`. It runs real PTY-backed shells with split panes and theming, and it supervises a local `opencode serve` instance — surfacing your OpenCode sessions in a sidebar so you can jump back into any of them in a terminal attached to the server.

> Status: a personal, experimental project. It is **not code-signed or notarized** — see [Unsigned app](#unsigned-app--opening-it).

## Features

- Real terminal sessions powered by libghostty, with hundreds of built-in color themes and a configurable font.
- Split panes (side-by-side and stacked), draggable dividers (double-click to recenter), and pane navigation.
- OpenCode integration: auto-starts `opencode serve`, lists sessions and projects in a sidebar, and lets you open, create, rename, and delete sessions.
- Configurable keyboard shortcuts plus a global show/hide hotkey.

## Requirements

- macOS 14 (Sonoma) or later.
- The Swift 6 toolchain to build — ships with Xcode 16+, or install from [swift.org](https://www.swift.org/install/).
- The `opencode` CLI on your `PATH` (or in `~/.opencode/bin`, or installed via Homebrew) for the OpenCode features. Without it, terminals still work and the OpenCode sidebar is simply empty.
- To build the `.app` bundle only: `librsvg` (`rsvg-convert`); `iconutil` ships with macOS. For example: `brew install librsvg`.

## Build & run

From the repository root:

```sh
# Run directly (debug)
swift run

# …or build, then launch the binary
swift build
.build/debug/Poltergeist

# Optimized build
swift build -c release
```

To produce a double-clickable `Poltergeist.app` (with the generated icon):

```sh
scripts/package-app.sh          # release by default → dist/Poltergeist.app
scripts/package-app.sh debug    # debug build instead
```

## Unsigned app — opening it

Poltergeist is **not code-signed or notarized**, and it intentionally runs **without the macOS App Sandbox** (required in order to spawn real pseudo-terminals). Because of this, Gatekeeper will refuse to open the packaged app on first launch.

To open it:

- Right-click (Control-click) `Poltergeist.app` → **Open**, then **Open** again in the dialog, **or**
- Clear the quarantine flag from a terminal:

  ```sh
  xattr -dr com.apple.quarantine dist/Poltergeist.app
  ```

Only run builds you trust — ideally ones you have built yourself from source.

## Configuration

Open **Settings** (⌘,) to configure:

- **Appearance** — light/dark themes and inactive-pane dimming.
- **Keyboard** — rebind most shortcuts and the global show/hide hotkey.

Settings persist to `~/Library/Application Support/Poltergeist/config.json`, which you can also edit by hand — changes apply live. Open terminal sessions are remembered in `sessions.json` in the same folder.

## Reporting issues

Please file bugs and feature requests on the issue tracker:

**https://github.com/tbremer/poltergeist/issues**

When reporting a bug, include your macOS version, how you launched the app (`swift run` vs. the packaged `.app`), and steps to reproduce.

## Built with

- [libghostty-spm](https://github.com/lakr233/libghostty-spm) — the Ghostty terminal core, packaged for Swift.
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — user-customizable global hotkeys.
