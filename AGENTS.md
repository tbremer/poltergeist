# AGENTS.md

A map of Poltergeist for coding agents — pointers and non-obvious facts, not an exhaustive mirror. General Swift/SwiftUI/AppKit knowledge is assumed.

## What this is
A **macOS-only, single-window SwiftUI terminal emulator** built on libghostty (`GhosttyKit`/`GhosttyTerminal`) that is "OpenCode-aware": it connects to opencode v2's shared background service (or, as a fallback, a private `opencode serve` it spawns) and lists its sessions in a sidebar. Two unusual traits drive everything:
- It is a **real terminal** — each session is a PTY (via a tiny C shim, `CPty`) feeding GhosttyKit's `.inMemory` backend. This requires running **without App Sandbox** (an SPM executable, not a sandboxed .app), and libghostty is statically linked.
- It is **not a document app**: one window, but it stays alive when that window closes (`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` is `false`). `AppModel` (terminals + opencode server) lives at app scope, so it survives a close; `applicationShouldHandleReopen` brings the window back (dock click), and the global hotkey re-shows it after a hide.

## Core mental model
Two parallel "session" concepts that are easy to conflate:
1. **Terminal sessions** (`TerminalSession`) — a live PTY + GhosttyKit surface. Owned by `SessionStore`. A sidebar "Sessions" row (a tab) is one of these.
2. **OpenCode sessions** (`OpencodeSession`) — server-side records fetched over REST/SSE, shown in the sidebar's project file-tree. Owned by `AppModel`.

They meet in `AppModel.openOpencodeSession`, which spawns a terminal running `opencode --session <id> [<directory>]` — plus `--server <url>` and a per-terminal `OPENCODE_PASSWORD` only when on a private server (opencode v2 removed the `attach` subcommand and its `--dir` flag) (so a terminal can be *attached* to an opencode session via `TerminalSession.opencodeSessionID`).

**Panes:** splitting a tab builds a per-tab binary tree (`PaneNode`, in `Pane.swift`). Split panes are extra `TerminalSession`s that live **only in the tree** (`SessionStore.paneTrees`), never in the sidebar list. Critical rendering rule: the tree is drawn **flat** by `PaneTabView` — every surface is rendered once, keyed by `session.id`, positioned by a frame computed from the tree. Restructuring (split/close/resize) only changes frames, so a surviving pane's surface is never torn down (preserving scrollback + first-responder). Do not reintroduce a recursive split-view tree.

## Architecture & canonical data flow
Layering: `PoltergeistApp` (@main) → `AppModel` (top-level state: server + store + opencode data) → `SessionStore` (terminals, panes, persistence) → `TerminalSession` (PTY + GhosttyKit surface) → `PTYProcess` → `CPty` (`forkpty`).

End-to-end keystroke trace: GhosttyKit `AppTerminalView.keyDown` → `InMemoryTerminalSession.write` → `PTYProcess.write` (master fd). Output: `PTYProcess.readAvailable` → `onOutput` → `InMemoryTerminalSession.receive` → surface renders.

Shortcut trace: global `NSEvent` keyDown monitor (`AppModel.installShortcutMonitor`) → `handleTerminalShortcut` → matches a configurable `KeyboardShortcuts.Name` (via `getShortcut`) or a fixed keyCode → `store.splitFocusedPane` / `closeFocusedPane` / etc. This runs **before** the menu/responder chain, which is why it can claim keys the Ghostty surface would otherwise swallow.

OpenCode trace: `AppModel.init` → `OpencodeServerManager.start` (shared service from `~/.local/state/opencode/service.json` → else `opencode service start` → else private `serve`) → publishes `connection` → `OpencodeClient` v2 REST + `OpencodeEventStream` SSE (session lifecycle events → debounced refresh; streaming chatter filtered) → `AppModel.rebuildTree` → `projectTree` → `RootView` sidebar.

## File map (open just-in-time)
- `Sources/Poltergeist/PoltergeistApp.swift` — @main `App`, the `Session` menu, `AppDelegate`. Entry point.
- `Sources/Poltergeist/RootView.swift` — the whole UI shell (sidebar + `TerminalDetailView`). **Best UI starting file.** Note: 2-space indented (see Conventions).
- `Sources/Poltergeist/AppModel.swift` — top-level `@MainActor` state; opencode refresh; the key-shortcut monitor + configurable `KeyboardShortcuts.Name`s.
- `Sources/Poltergeist/SessionStore.swift` — terminals, selection, pane tree (split/close/resize/focus), persistence.
- `Sources/Poltergeist/TerminalSession.swift` — one PTY+surface; `state: TerminalViewState` (focus via `state.isFocused`), `applyAppearance`.
- `Sources/Poltergeist/Pane.swift` — `PaneNode` tree + `replacingLeaf`/`removingLeaf`/`settingFraction`.
- `Sources/Poltergeist/PaneTreeView.swift` — `PaneTabView` (flat layout), `DividerHandle`, `PaneLeafView` (dim + focus side-effect).
- `Sources/Poltergeist/PTYProcess.swift` + `Sources/CPty/` — PTY lifecycle; `CPty` exists for `forkpty`/`TIOCSWINSZ` which Swift can't call directly.
- `Sources/Poltergeist/OpencodeServerManager.swift` — locates the `opencode` binary; discovers/starts the shared v2 service (never stops it) or falls back to a private password-protected `serve` (auto-restarted, stopped on quit); `revalidate()` re-discovers after failures. Publishes `OpencodeConnection` (`baseURL`, `password`, `isShared`).
- `Sources/Poltergeist/OpencodeClient.swift` — v2 REST (`/api/session` list/create/PATCH/DELETE, HTTP Basic `opencode:<password>`, `{data}` envelopes); `OpencodeEventStream.swift` — SSE (`/api/event`); `OpencodeModels.swift` — `OpencodeSession` (decodes v2 `location.directory` and the flat cached `directory`)/`ProjectTreeNode` + computed props (`isStale`, `isRecentlyActive`, `updatedRelative`, `totalTokens`).
- `Sources/Poltergeist/SettingsView.swift` — Settings scene (Appearance + Keyboard tabs).
- `Sources/Poltergeist/SessionSwitcher.swift` — collapsed-sidebar session switcher: `SidebarCollapseObserver` (reads collapse from the real `NSSplitViewItem`, since the `columnVisibility` binding is unreliable with the `toggleSidebar:` action) + `SessionSwitcherButton` (hover/click popover of active sessions with ⌘-number labels). The configurable `sessionSwitcher` hotkey (default ⇧⌥⌘B) bumps `AppModel.sessionSwitcherNonce`; RootView then force-shows the toolbar item (even with the sidebar open) and opens the menu keyboard-focused (↑/↓, Return, Esc, 1–9/0). Hover-opened menus deliberately don't take keyboard focus.
- `Sources/Poltergeist/{AppConfig,PersistedState,AppPaths,ConfigWatcher}.swift` — config/persistence plumbing.
- `scripts/package-app.sh` — builds + assembles `dist/Poltergeist.app` with a generated icon.

## Legacy / dormant (distractors)
- Scrollback persistence was **removed**; `SessionStore.init` still deletes a leftover `scrollback/` dir. Do not try to persist/replay scrollback (it re-feeds capability queries and garbles output).
- `PersistedState.expandedGroups` is legacy (pre-tree sidebar) and ignored; `collapsedGroups` is the live one.
- `.build/checkouts/libghostty-spm/` has its own `AGENTS.md` describing the **library** (its example apps are sandboxed and forbid PTYs). That guidance does **not** apply to this app — ignore it here.

## Conventions & idioms
- Concurrency/state: stateful types are `@MainActor final class … ObservableObject` with `@Published`; cross-thread work hops back via `MainActor.assumeIsolated`.
- Indentation: **4-space everywhere except `RootView.swift`, which is 2-space.** Match the file you are editing.
- Shortcuts: configurable actions are `KeyboardShortcuts.Name`s with `initial:` defaults but **no `onKeyUp` handler**, so they are NOT registered as global hotkeys — `handleTerminalShortcut` matches them locally via `getShortcut`. Only `togglePoltergeist` is a true global hotkey. Fixed shortcuts (⌘1–9/⌘0 select session, ⌘W close pane, ⌘⇧W close window, ⌘, settings, ⌘Q quit) are hardcoded in `handleTerminalShortcut` — mostly by keyCode, except ⌘-digit which matches `charactersIgnoringModifiers`. To add a configurable shortcut: add a `Name`, a `matches(event,)` branch, and a `Recorder` row in `SettingsView`.
- The monitor gates on `windowHostsTerminal(NSApp.keyWindow)` (main window contains a terminal view), **not** on first-responder — this is deliberate; do not revert it (see Gotchas).
- Focus is first-responder-driven, never via `.terminalFocused`. The active pane is read from `session.state.isFocused`. To move focus programmatically use `SessionStore.focusSurface(of:)` (a one-shot `makeFirstResponder` with retry).
- Live config reload: `ConfigWatcher` watches the **directory** (not the file) so atomic-rename saves are caught; `AppModel.applyConfig` re-applies.
- To run a Settings action from the monitor (which isn't a View), bump a `@Published` nonce that `RootView` observes (see `openSettingsNonce`); the sidebar toggle instead calls AppKit's `toggleSidebar:` directly.

## Build / run / setup
- Build: `swift build` (debug → `.build/debug/Poltergeist`) or `swift build -c release`.
- Package the app: `scripts/package-app.sh [debug|release]` (default release) → `dist/Poltergeist.app`. Needs `rsvg-convert`, `iconutil`, `swift`; icon derives from `icon/master.svg`.
- Smoke test (no UI): launch the binary in the background, capture **its** PID (`$!`), wait ~5s, confirm with `kill -0 $PID`, then stop **only that PID** (and any private `serve` it spawned — find it as a child via `pgrep -P $PID`). The user typically has their own Poltergeist running: never quit/kill by name or pattern (`osascript … quit app "Poltergeist"`, `pkill -f Poltergeist`, `pkill -f 'opencode serve'`) — that hits their instance and its server. Never kill the shared opencode service either.
- Runtime needs the `opencode` binary on PATH / `~/.opencode/bin` / homebrew; absent, opencode features degrade gracefully but terminals still work.
- Isolated test instance: set `POLTERGEIST_SUPPORT_DIR=<dir>` so config/sessions/cache live there instead of the shared support dir (otherwise a dev build restores — and on quit overwrites — the installed app's `sessions.json`).
- Config: `~/Library/Application Support/Poltergeist/config.json` (theme/font/inactive-pane dimming). Session metadata: `sessions.json` (same dir). `dist/`, `.build/`, `.vscode/` are gitignored.
- Deps: `libghostty-spm` pinned `exact: 1.2.5`; `KeyboardShortcuts` `from: 3.0.0`.

## Gotchas / known issues
- ⌘W must reach `closeFocusedPane`, not the default File→Close (which closes the window). The `windowHostsTerminal` monitor guard + re-focusing a neighbor pane on close keep ⌘W on the pane. Closing the window no longer quits the app, but it still tears down the on-screen surfaces (scrollback resets on reopen; the PTYs/sessions survive).
- New Ghostty surfaces default to **focused** (solid blinking cursor) and there is no public `setFocus`. So `PaneLeafView`, on gaining focus, calls `SessionStore.unfocusOtherPanes` (forces `resignFirstResponder` on the others). Without it, every pane blinks.
- Do not write `@Published` `SessionStore` state in response to a focus change — the resulting re-render drops the terminal's first responder and breaks typing. `unfocusOtherPanes` is intentionally a pure view side-effect.
- **Regression point — sidebar clicks stealing keyboard focus.** Clicking the sidebar `List` makes its `NSOutlineView` first responder, so typing goes nowhere. The fix is `AppModel.installSidebarClickMonitor`: on a left mouse-down inside an `NSTableView` in the terminal window, it polls `NSEvent.pressedMouseButtons` until release, then — if the table still holds focus — calls `SessionStore.focusSelectedSession()`. Do **not** "simplify" this into a row `onTapGesture`/`simultaneousGesture` or a mouse-up event monitor: the outline view runs its own tracking loop on mouse-down and swallows the mouse-up ~half the time (measured: tap handlers fired on ~50% of clicks), and re-clicking the already-selected row never changes selection. Accepted trade-off: after a sidebar click, focus returns to the terminal, so arrow-key browsing of the list doesn't stick. Diagnose focus issues with `POLTERGEIST_DEBUG_FOCUS=1` (see `FocusDebug.swift`): it logs first-responder changes, focus attempts, selection, clicks, and keyDown targets (key codes only).
- The sidebar/switcher sparkle reflects `TerminalSession.opencodeActive`, not `opencodeSessionID`: `SessionStore` polls every 1.5s, asking each pane's PTY for its foreground process group (`tcgetpgrp` on the master fd → `sysctl KERN_PROC_PGRP` → `p_comm`) and setting the tab's flag if any pane's foreground job is `opencode`. It only writes the per-session flag on change — keep it off store-level `@Published` state (focus gotcha below). The opencode metadata line is still keyed on `opencodeSessionID`.
- `PTYProcess` spawns its child **lazily on the first non-empty resize** (GhosttyKit drops bytes until the surface is attached).
- opencode **v2** server API (v1 is gone): everything is under `/api/…` with HTTP Basic auth. Unknown paths (e.g. v1's `/session`) return the web UI's HTML with a **200**, so never health-check a bare path — `isHealthy` uses an authenticated `/api/info`. `/api/session` is global (all projects) and cursor-paginated (`cursor.next`); pass `parentID=null` for root sessions.
- `AppModel` throttles refreshes (`refreshQuietUntil`) right after spawning a terminal so the new shell's startup capability queries get the main thread (otherwise replies leak to the prompt as garble).
- Toggle-sidebar is a single configurable combo (default ⌥⌘B), not the old ⌘K⌘B chord (recorders can't capture chords).

## Security considerations
- Runs **without App Sandbox** by design (PTY). Terminals inherit the user's full environment; no opencode credentials are injected into ordinary shells (a private server's password goes only into its attach terminal, so a plain `opencode` never sends it to the shared service).
- The fallback private `opencode serve` binds `127.0.0.1` on a random free port with a generated password (`OPENCODE_PASSWORD`). Do not expose it on `0.0.0.0`, and never put the password in argv (visible in `ps`).
- Personal/unsigned dev build; no secrets in the repo.

## Working agreement for agents
- Default to the live path; read the file before assuming, and match its indentation (4-space; 2-space in `RootView.swift`).
- Don't reintroduce `.terminalFocused`, recursive pane-tree views, scrollback persistence, first-responder-based shortcut gating, or tap-gesture-based sidebar focus return — each caused a fixed bug.
- After touching the sidebar, `SessionStore` focus/selection, or `AppModel`'s event monitors, re-test "click a sidebar row → type immediately" (including re-clicking the selected row) with `POLTERGEIST_DEBUG_FOCUS=1` and confirm every keyDown lands on `terminal(...)`.
- After changes: `swift build` and run the smoke test; repackage with `scripts/package-app.sh` when verifying the bundled app.
- Don't introduce new architecture (DI frameworks, extra windows, global hotkeys for local actions) unprompted.
