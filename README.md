<p align="center">
  <img src="icon/AppIcon.png" width="160" height="160" alt="Poltergeist icon">
</p>

<h1 align="center">Poltergeist</h1>

<p align="center">A macOS terminal that's aware of OpenCode.</p>

Poltergeist is a single-window macOS terminal emulator built on [Ghostty](https://github.com/ghostty-org/ghostty)'s `libghostty`. It runs real PTY-backed shells with split panes and theming, and it connects to OpenCode's background service — surfacing your OpenCode sessions in a sidebar so you can jump back into any of them in a terminal.

> Status: a personal, experimental project. It is **not code-signed or notarized** — see [Unsigned app](#unsigned-app--opening-it).

## Features

- Real terminal sessions powered by libghostty, with hundreds of built-in color themes and a configurable font.
- Split panes (side-by-side and stacked), draggable dividers (double-click to recenter), and pane navigation.
- OpenCode integration (OpenCode v2): uses OpenCode's shared background service (starting it if needed), lists sessions by project in a sidebar, and lets you open, create, rename, and delete sessions.
- OpenCode-aware tabs: a tab shows a ✨ sparkle while `opencode` is the foreground program in any of its panes — whether you opened it from the sidebar or ran `opencode` by hand — and goes back to a terminal icon when it exits.
- Fast session switching: ⌘1–⌘9 jump to a tab (⌘0 = last), and a session switcher (⇧⌥⌘B, or hover the stack icon by the traffic lights when the sidebar is collapsed) works by mouse or keyboard.
- Selecting a session — by click, shortcut, or switcher — puts keyboard focus straight into its terminal.
- Configurable keyboard shortcuts plus a global show/hide hotkey.
- Stays running when its window is closed; click the Dock icon or use the hotkey to bring it back.

## Requirements

- macOS 14 (Sonoma) or later.
- The Swift 6 toolchain to build — ships with Xcode 16+, or install from [swift.org](https://www.swift.org/install/).
- The `opencode` CLI, **version 2 or later**, on your `PATH` (or in `~/.opencode/bin`, or installed via Homebrew) for the OpenCode features. Without it, terminals still work and the OpenCode sidebar is simply empty.
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

## Keyboard shortcuts

| Action | Default |
| --- | --- |
| Show/hide Poltergeist (global) | ⌃⌥⌘P |
| New terminal | ⌘T |
| New OpenCode session | ⇧⌘T |
| Next / previous session | ⇧⌘] / ⇧⌘[ |
| Go to session 1–9 / last | ⌘1–⌘9 / ⌘0 |
| Session switcher | ⇧⌥⌘B |
| Toggle sidebar | ⌥⌘B |
| Split right / down | ⌘D / ⇧⌘D |
| Focus next / previous pane | ⌘] / ⌘[ |
| Close pane / close window | ⌘W / ⇧⌘W |
| Settings | ⌘, |

Everything except the ⌘-number, close, and Settings shortcuts can be rebound in **Settings → Keyboard**. In the session switcher, use ↑/↓ and Return to pick, 1–9/0 to jump, and Esc to close.

## Configuration

Open **Settings** (⌘,) to configure:

- **Appearance** — light/dark themes and inactive-pane dimming.
- **Keyboard** — rebind most shortcuts and the global show/hide hotkey.

Settings persist to `~/Library/Application Support/Poltergeist/config.json`, which you can also edit by hand — changes apply live. Open terminal sessions are remembered in `sessions.json` in the same folder.

## Development

- `POLTERGEIST_SUPPORT_DIR=<dir>` keeps config, sessions, and cache in `<dir>` instead of `~/Library/Application Support/Poltergeist/`. Use it to run a dev build next to an installed copy without overwriting its `sessions.json`:

  ```sh
  POLTERGEIST_SUPPORT_DIR=/tmp/poltergeist-dev .build/debug/Poltergeist
  ```

- `POLTERGEIST_DEBUG_FOCUS=1` logs keyboard-focus diagnostics to stderr: first-responder changes, focus attempts, selection changes, clicks, and where each keypress landed. Only key codes are logged, never the characters typed.

See [`AGENTS.md`](AGENTS.md) for an architecture overview and known pitfalls.

## Reporting issues

Please file bugs and feature requests on the issue tracker:

**https://github.com/tbremer/poltergeist/issues**

When reporting a bug, include your macOS version, how you launched the app (`swift run` vs. the packaged `.app`), and steps to reproduce.

## Built with

- [libghostty-spm](https://github.com/lakr233/libghostty-spm) — the Ghostty terminal core, packaged for Swift.
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — user-customizable global hotkeys.
