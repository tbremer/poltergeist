# AGENTS.md

A map of Poltergeist for coding agents — pointers and non-obvious facts, not an exhaustive mirror. General Swift/SwiftUI/AppKit knowledge is assumed.

## What this is
A **macOS-only, single-window SwiftUI terminal emulator** built on libghostty (`GhosttyKit`/`GhosttyTerminal`) that is "OpenCode-aware": it spawns and supervises a local `opencode serve` process and lists its sessions in a sidebar. Two unusual traits drive everything:
- It is a **real terminal** — each session is a PTY (via a tiny C shim, `CPty`) feeding GhosttyKit's `.inMemory` backend. This requires running **without App Sandbox** (an SPM executable, not a sandboxed .app), and libghostty is statically linked.
- It is **not a document app**: one window. `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `true`, so closing the last window quits the process (see Gotchas — this is why ⌘W routing matters).

## Core mental model
Two parallel "session" concepts that are easy to conflate:
1. **Terminal sessions** (`TerminalSession`) — a live PTY + GhosttyKit surface. Owned by `SessionStore`. A sidebar "Sessions" row (a tab) is one of these.
2. **OpenCode sessions** (`OpencodeSession`) — server-side records fetched over REST/SSE, shown in the sidebar's project file-tree. Owned by `AppModel`.

They meet in `AppModel.openOpencodeSession`, which spawns a terminal running `opencode attach <baseURL> --session <id>` (so a terminal can be *attached* to an opencode session via `TerminalSession.opencodeSessionID`).

**Panes:** splitting a tab builds a per-tab binary tree (`PaneNode`, in `Pane.swift`). Split panes are extra `TerminalSession`s that live **only in the tree** (`SessionStore.paneTrees`), never in the sidebar list. Critical rendering rule: the tree is drawn **flat** by `PaneTabView` — every surface is rendered once, keyed by `session.id`, positioned by a frame computed from the tree. Restructuring (split/close/resize) only changes frames, so a surviving pane's surface is never torn down (preserving scrollback + first-responder). Do not reintroduce a recursive split-view tree.

## Architecture & canonical data flow
Layering: `PoltergeistApp` (@main) → `AppModel` (top-level state: server + store + opencode data) → `SessionStore` (terminals, panes, persistence) → `TerminalSession` (PTY + GhosttyKit surface) → `PTYProcess` → `CPty` (`forkpty`).

End-to-end keystroke trace: GhosttyKit `AppTerminalView.keyDown` → `InMemoryTerminalSession.write` → `PTYProcess.write` (master fd). Output: `PTYProcess.readAvailable` → `onOutput` → `InMemoryTerminalSession.receive` → surface renders.

Shortcut trace: global `NSEvent` keyDown monitor (`AppModel.installShortcutMonitor`) → `handleTerminalShortcut` → matches a configurable `KeyboardShortcuts.Name` (via `getShortcut`) or a fixed keyCode → `store.splitFocusedPane` / `closeFocusedPane` / etc. This runs **before** the menu/responder chain, which is why it can claim keys the Ghostty surface would otherwise swallow.

OpenCode trace: `AppModel.init` → `OpencodeServerManager.start` (spawns `opencode serve` on a pre-picked free 127.0.0.1 port) → `OpencodeClient` REST + `OpencodeEventStream` SSE (any event → debounced refresh) → `AppModel.rebuildTree` → `projectTree` → `RootView` sidebar.

## File map (open just-in-time)
- `Sources/Poltergeist/PoltergeistApp.swift` — @main `App`, the `Session` menu, `AppDelegate`. Entry point.
- `Sources/Poltergeist/RootView.swift` — the whole UI shell (sidebar + `TerminalDetailView`). **Best UI starting file.** Note: 2-space indented (see Conventions).
- `Sources/Poltergeist/AppModel.swift` — top-level `@MainActor` state; opencode refresh; the key-shortcut monitor + configurable `KeyboardShortcuts.Name`s.
- `Sources/Poltergeist/SessionStore.swift` — terminals, selection, pane tree (split/close/resize/focus), persistence.
- `Sources/Poltergeist/TerminalSession.swift` — one PTY+surface; `state: TerminalViewState` (focus via `state.isFocused`), `applyAppearance`.
- `Sources/Poltergeist/Pane.swift` — `PaneNode` tree + `replacingLeaf`/`removingLeaf`/`settingFraction`.
- `Sources/Poltergeist/PaneTreeView.swift` — `PaneTabView` (flat layout), `DividerHandle`, `PaneLeafView` (dim + focus side-effect).
- `Sources/Poltergeist/PTYProcess.swift` + `Sources/CPty/` — PTY lifecycle; `CPty` exists for `forkpty`/`TIOCSWINSZ` which Swift can't call directly.
- `Sources/Poltergeist/OpencodeServerManager.swift` — locates the `opencode` binary, picks a port, runs/health-checks/stops `opencode serve`.
- `Sources/Poltergeist/OpencodeClient.swift` — REST (`/session`, `/project`); `OpencodeEventStream.swift` — SSE; `OpencodeModels.swift` — `OpencodeSession`/`OpencodeProject`/`ProjectTreeNode` + computed props (`isStale`, `isRecentlyActive`, `updatedRelative`, `totalTokens`).
- `Sources/Poltergeist/SettingsView.swift` — Settings scene (Appearance + Keyboard tabs).
- `Sources/Poltergeist/{AppConfig,PersistedState,AppPaths,ConfigWatcher}.swift` — config/persistence plumbing.
- `scripts/package-app.fish` — builds + assembles `dist/Poltergeist.app` with a generated icon.

## Legacy / dormant (distractors)
- Scrollback persistence was **removed**; `SessionStore.init` still deletes a leftover `scrollback/` dir. Do not try to persist/replay scrollback (it re-feeds capability queries and garbles output).
- `PersistedState.expandedGroups` is legacy (pre-tree sidebar) and ignored; `collapsedGroups` is the live one.
- `.build/checkouts/libghostty-spm/` has its own `AGENTS.md` describing the **library** (its example apps are sandboxed and forbid PTYs). That guidance does **not** apply to this app — ignore it here.

## Conventions & idioms
- Concurrency/state: stateful types are `@MainActor final class … ObservableObject` with `@Published`; cross-thread work hops back via `MainActor.assumeIsolated`.
- Indentation: **4-space everywhere except `RootView.swift`, which is 2-space.** Match the file you are editing.
- Shortcuts: configurable actions are `KeyboardShortcuts.Name`s with `initial:` defaults but **no `onKeyUp` handler**, so they are NOT registered as global hotkeys — `handleTerminalShortcut` matches them locally via `getShortcut`. Only `togglePoltergeist` is a true global hotkey. Fixed shortcuts (⌘W close pane, ⌘⇧W close window, ⌘, settings, ⌘Q quit) are hardcoded by keyCode. To add a configurable shortcut: add a `Name`, a `matches(event,)` branch, and a `Recorder` row in `SettingsView`.
- The monitor gates on `windowHostsTerminal(NSApp.keyWindow)` (main window contains a terminal view), **not** on first-responder — this is deliberate; do not revert it (see Gotchas).
- Focus is first-responder-driven, never via `.terminalFocused`. The active pane is read from `session.state.isFocused`. To move focus programmatically use `SessionStore.focusSurface(of:)` (a one-shot `makeFirstResponder` with retry).
- Live config reload: `ConfigWatcher` watches the **directory** (not the file) so atomic-rename saves are caught; `AppModel.applyConfig` re-applies.
- To run a Settings action from the monitor (which isn't a View), bump a `@Published` nonce that `RootView` observes (see `openSettingsNonce`); the sidebar toggle instead calls AppKit's `toggleSidebar:` directly.

## Build / run / setup
- Build: `swift build` (debug → `.build/debug/Poltergeist`) or `swift build -c release`.
- Package the app: `fish scripts/package-app.fish [debug|release]` (default release) → `dist/Poltergeist.app`. Needs `rsvg-convert`, `iconutil`, `swift`; icon derives from `icon/master.svg`.
- Smoke test (no UI): launch the binary ~5s, confirm with `kill -0 $PID`, then `pkill -9 -f 'debug/Poltergeist'` and `pkill -9 -f 'opencode/bin/opencode serve'` (kill the spawned server too).
- Runtime needs the `opencode` binary on PATH / `~/.opencode/bin` / homebrew; absent, opencode features degrade gracefully but terminals still work.
- Config: `~/Library/Application Support/Poltergeist/config.json` (theme/font/inactive-pane dimming). Session metadata: `sessions.json` (same dir). `dist/`, `.build/`, `.vscode/` are gitignored.
- Deps: `libghostty-spm` pinned `exact: 1.2.5`; `KeyboardShortcuts` `from: 3.0.0`.

## Gotchas / known issues
- ⌘W must reach `closeFocusedPane`. If focus is briefly lost and ⌘W falls through to the default File→Close, it closes the only window and **quits the app**. The `windowHostsTerminal` monitor guard + re-focusing a neighbor pane on close both exist to prevent this.
- New Ghostty surfaces default to **focused** (solid blinking cursor) and there is no public `setFocus`. So `PaneLeafView`, on gaining focus, calls `SessionStore.unfocusOtherPanes` (forces `resignFirstResponder` on the others). Without it, every pane blinks.
- Do not write `@Published` `SessionStore` state in response to a focus change — the resulting re-render drops the terminal's first responder and breaks typing. `unfocusOtherPanes` is intentionally a pure view side-effect.
- `PTYProcess` spawns its child **lazily on the first non-empty resize** (GhosttyKit drops bytes until the surface is attached).
- `OpencodeClient` passes `limit=1000`: the server caps `/session` at 100 and ignores offset/cursor.
- `AppModel` throttles refreshes (`refreshQuietUntil`) right after spawning a terminal so the new shell's startup capability queries get the main thread (otherwise replies leak to the prompt as garble).
- Toggle-sidebar is a single configurable combo (default ⌥⌘B), not the old ⌘K⌘B chord (recorders can't capture chords).

## Security considerations
- Runs **without App Sandbox** by design (PTY). Terminals inherit the user's full environment plus `OPENCODE_BASE_URL`.
- `opencode serve` binds `127.0.0.1` on a random free port with no auth — localhost-only is the trust boundary. Do not expose it on `0.0.0.0` or add it to args.
- Personal/unsigned dev build; no secrets in the repo.

## Working agreement for agents
- Default to the live path; read the file before assuming, and match its indentation (4-space; 2-space in `RootView.swift`).
- Don't reintroduce `.terminalFocused`, recursive pane-tree views, scrollback persistence, or first-responder-based shortcut gating — each caused a fixed bug.
- After changes: `swift build` and run the smoke test; repackage with `scripts/package-app.fish` when verifying the bundled app.
- Don't introduce new architecture (DI frameworks, extra windows, global hotkeys for local actions) unprompted.
