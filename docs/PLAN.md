# Clawdboard — Implementation Plan

## Context
Building a native macOS menu bar app in SwiftUI for managing multiple Claude Code agent sessions. Session discovery is a core feature from day one — not future work. Context Inbox tab is deferred (unclear UX, will iterate later).

## SwiftUI Concepts Used (Quick Reference)

- **`@main` App struct** — Entry point, like `index.tsx`. Declares scenes (windows, menu bar items).
- **`MenuBarExtra`** — Scene that creates a menu bar icon. `.menuBarExtraStyle(.window)` makes it show a SwiftUI panel on click.
- **`@Observable`** — Makes a class reactive (like MobX). Views auto-re-render when read properties change.
- **`@State`** — Local state in a view (like `useState`). We use it to own the AppState instance.
- **`.environment()`** — DI for the view tree (like React Context). Child views grab it with `@Environment(AppState.self)`.
- **`VStack/HStack/ZStack`** — flex-direction: column / row / position: absolute stacking.
- **View modifiers** — `.padding()`, `.background()`, `.font()` — like CSS but chained, order matters.

## Session Discovery & Monitoring Architecture

**Hooks-first design.** Claude hooks are a public API — file paths in `~/.claude/` are private implementation details. Hooks are the primary mechanism; file scanning is a minimal fallback for pre-hook sessions.

### How It Works

```
Claude hooks fire → bash script reads JSONL tail via python3 →
  writes complete state to ~/.clawdboard/sessions/{id}.json →
    Swift app watches ~/.clawdboard/sessions/ → updates UI
```

The Swift app does NOT parse JSONL or scan processes for status. It reads clean JSON state files written by hooks.

### Hook Events We Use

| Hook | When | What the script writes |
|------|------|----------------------|
| `SessionStart` | Session begins | Create state file: `{session_id, cwd, status: "working", started_at}` |
| `PostToolUse` | After each tool call | Update: token counts, cost, context %, model (from JSONL tail) |
| `Stop` | Agent considers stopping | Update: `status: "pending_waiting"` (with 3s debounce — see below) |
| `UserPromptSubmit` | User sends message | Update: `status: "working"` |
| `Notification:idle_prompt` | Idle 60s+ | Confirm: `status: "waiting"` (backup signal) |
| `SessionEnd` | Session closes | Delete state file |

### Hook Script Design (bash + python3)

Each hook is a small bash script installed at `~/.clawdboard/hooks/`. They:
1. Read JSON from stdin (hook input: `session_id`, `transcript_path`, `cwd`, `hook_event_name`)
2. Use `tail -1 $transcript_path | python3 -c "..."` to extract token usage from the last JSONL entry
3. Calculate cost using model pricing
4. Write/update `~/.clawdboard/sessions/{session_id}.json`

### State File Format (`~/.clawdboard/sessions/{session_id}.json`)

```json
{
  "session_id": "42ac740e-4596-49a9-b544-73ad2f8b5f79",
  "cwd": "/Users/radek/Code/clawdboard",
  "project_name": "clawdboard",
  "status": "waiting",
  "model": "claude-opus-4-6",
  "git_branch": "main",
  "slug": "pure-tickling-dewdrop",
  "cost_usd": 1.47,
  "context_pct": 68.5,
  "input_tokens": 137000,
  "output_tokens": 42000,
  "started_at": "2026-03-12T08:44:59Z",
  "updated_at": "2026-03-12T09:12:33Z"
}
```

### What the Swift App Does

1. **Watches `~/.clawdboard/sessions/`** via `DispatchSource.makeFileSystemObjectSource` — instant state file change detection
2. **Polls every 5s** as safety net — re-reads all state files, cleans up stale ones
3. **Validates PID liveness** — IDE lock files (from `~/.claude/ide/`) give us PIDs to check
4. **Pre-hook fallback** — for sessions started before hooks installed: detect via IDE lock files + processes, show with "unknown" status and a hint to restart

### Waiting-for-Input Detection (3s Debounce)

The `Stop` hook fires when the agent "considers stopping" but may fire mid-chain. The hook script handles debounce:
1. `Stop` hook writes `status: "pending_waiting"` with timestamp
2. `PostToolUse` / `UserPromptSubmit` hooks clear the pending state → back to "working"
3. Swift app: if a session has been `"pending_waiting"` for 3+ seconds → display as "waiting" (amber)
4. `idle_prompt` hook confirms "waiting" definitively (no debounce needed)

### Cost Calculation (in hook script, via python3)

Token counts from JSONL `usage` object × model pricing:
```
cost = (input × rate) + (output × rate) + (cache_write × rate) + (cache_read × rate)
```
Pricing per 1M tokens: Opus ($15/$75), Sonnet ($3/$15), Haiku ($0.25/$1.25). Cache write 1.25× input, cache read 0.1× input.

### Context Usage % (in hook script)

```
context_pct = (input_tokens + cache_creation + cache_read + output_tokens) / 180_000 × 100
```
All three token types occupy the context window. Cache reads are cheap but still fill it.

### Fallback for Pre-Hook Sessions

Sessions started before Clawdboard installs hooks won't fire events. Minimal fallback:
- Scan `~/.claude/ide/*.lock` for IDE sessions (PID, workspace, IDE name)
- Scan `ps aux` for terminal CLI sessions (model from args)
- Show these with status "unknown" and a badge: "Restart session for full tracking"

## Key Architectural Decisions

### 1. Package.swift: Library + Executable split
SPM executable targets **cannot be imported by test targets**. So we split:
- `ClawdboardLib` — library with all code (models, state, views, discovery)
- `Clawdboard` — thin executable with just `@main` App entry point
- `ClawdboardTests` — tests importing ClawdboardLib

### 2. Single @Observable AppState
One class holds all state. `@Observable` gives granular tracking — views only re-render for properties they read. Owned by App struct, distributed via `.environment()`.

### 3. No third-party dependencies
Skip `KeyboardShortcuts` and `MenuBarExtraAccess`. ⌘⇧A is visual-only for now.

### 4. Dock hiding via code
`NSApplication.shared.setActivationPolicy(.accessory)` — no Info.plist needed.

### 5. Swift 5 language mode
Avoid Swift 6 strict concurrency fights while building a PoC. Set `swiftLanguageModes: [.v5]`.

### 6. swift-format for code formatting

### 7. Hook auto-install with confirmation
On first launch, show a macOS alert explaining that Clawdboard needs to add hooks to `~/.claude/settings.json` for real-time session status tracking. If user approves, merge hooks (preserving existing ones). "Reinstall Hooks" button in Settings for recovery.

### 8. 3-second debounce on Stop hook
When the `Stop` hook fires, wait 3s before marking session as "waiting". If new JSONL activity appears in that window, ignore the Stop signal. Prevents false "waiting" flicker during tool-use chains.

## File Structure

```
clawdboard/
├── Package.swift
├── Sources/
│   ├── Clawdboard/
│   │   └── ClawdboardApp.swift              # @main, MenuBarExtra + Settings scenes, owns AppState
│   └── ClawdboardLib/
│       ├── AppState.swift                    # @Observable: reads state files, UI state, computed props
│       ├── Models.swift                      # AgentSession, AgentStatus enum
│       ├── SessionStateWatcher.swift         # Watches ~/.clawdboard/sessions/ for state file changes
│       ├── HookManager.swift                 # Installs/updates Claude hooks in ~/.claude/settings.json
│       ├── FallbackDiscovery.swift           # Minimal: IDE lock files + process scan for pre-hook sessions
│       ├── Views/
│       │   ├── PanelView.swift               # Header with status pills + total cost, sessions list, footer
│       │   ├── SessionsTab.swift             # Active/Idle sections with sorted lists
│       │   ├── AgentRow.swift                # Expandable row: status dot, name, context bar, detail grid
│       │   ├── SettingsView.swift            # Form with @AppStorage toggles, reinstall hooks button
│       │   └── Components.swift              # StatusDot, ContextBar, ActionButton
├── hooks/                                    # Installed to ~/.clawdboard/hooks/
│   └── clawdboard-hook.sh                   # Bash script called by all Claude hooks
├── Tests/
│   └── ClawdboardTests/
│       ├── SessionStateWatcherTests.swift   # Parse state files, handle stale data
│       ├── HookManagerTests.swift           # Merge hooks into settings.json, preserve existing
│       ├── FallbackDiscoveryTests.swift     # Parse lock files, process args
│       └── AppStateTests.swift              # Computed props, sorting, debounce logic
├── scripts/
│   └── bundle.sh                            # Creates .app bundle from binary
├── Makefile                                 # build, run, test, format targets
├── .swift-format
└── .gitignore
```

**Key insight:** The Swift app is simple — it reads JSON state files from `~/.clawdboard/sessions/`. All the hard work (JSONL parsing, cost calculation, token counting) happens in `clawdboard-hook.sh`, which runs inside Claude's hook system.

**Dropped from spec:** Context Inbox (deferred), MenuBarLabel.swift (inline), Extensions.swift (YAGNI).
**Added:** Hook script, HookManager, SessionStateWatcher, FallbackDiscovery.

## Build Order

### Phase 1: Skeleton — get something on screen
1. `.gitignore`, `Package.swift` (lib + executable targets), `Makefile`
2. `Models.swift` — AgentSession (Codable, from state file JSON), AgentStatus enum
3. `ClawdboardApp.swift` — bare MenuBarExtra showing "Hello"
4. **Verify:** `make build && make run` → menu bar icon appears

### Phase 2: Hook script + installation
5. `hooks/clawdboard-hook.sh` — the bash+python3 script that reads JSONL, writes state files
6. `HookManager.swift` — reads `~/.claude/settings.json`, merges Clawdboard hooks, creates `~/.clawdboard/hooks/` and `~/.clawdboard/sessions/` dirs
7. First-launch confirmation dialog in ClawdboardApp
8. **Verify:** install hooks, start a Claude session → state file appears in `~/.clawdboard/sessions/`

### Phase 3: State watching + app state
9. `SessionStateWatcher.swift` — watches `~/.clawdboard/sessions/` via DispatchSource, parses state files
10. `FallbackDiscovery.swift` — minimal IDE lock file + process scan for pre-hook sessions
11. `AppState.swift` — @Observable, merges hook-tracked + fallback sessions, 3s debounce logic, computed props
12. Wire into app, display session count in menu bar label
13. **Verify:** real sessions appear, status updates when agent finishes a task

### Phase 4: Views
14. `Components.swift` — StatusDot (pulse for working, solid amber for waiting), ContextBar, ActionButton
15. `AgentRow.swift` — expandable row with detail grid (model, branch, cost, context %, session slug)
16. `SessionsTab.swift` — sections sorted by urgency: waiting (needs attention) > working > unknown
17. `PanelView.swift` — header with status summary + total cost, sessions list, footer
18. `SettingsView.swift` — reinstall hooks button, poll interval

### Phase 5: Polish
19. Menu bar icon with status dots (try colored circles, fallback to text count)
20. `setActivationPolicy(.accessory)` for dock hiding
21. Settings scene (⌘,)
22. Animations: pulse, expand/collapse, context bar fill
23. Amber dot in menu bar for sessions needing attention

### Phase 6: Tests + tooling
24. `SessionStateWatcherTests.swift` — parse state files, stale cleanup
25. `HookManagerTests.swift` — merge into settings.json, preserve existing hooks
26. `FallbackDiscoveryTests.swift` — lock file parsing, process arg extraction
27. `AppStateTests.swift` — computed props, sorting, debounce
28. `.swift-format`, format all code
29. `scripts/bundle.sh`

## Known Risks
- **Menu bar label:** Status dots may not render in NSStatusBarButton. Fallback: text count.
- **JSONL parsing in hook script:** Large session files — `tail -1` is O(1) for last line, but cumulative cost needs summing all usage lines. Mitigation: hook script maintains running totals in the state file.
- **IDE lock file staleness:** Lock files persist after crash. Always validate PID liveness.
- **Hook installation safety:** Must preserve existing hooks in `settings.json`. Read → merge → write atomically. User confirmation dialog on first install.
- **Hooks only load at session start:** Pre-hook sessions show as "unknown" status with restart hint.
- **`Stop` hook false positives:** May fire mid-chain. 3s debounce in Swift app (not in hook script — script just writes the state, app interprets timing).
- **Python3 availability:** Required for hook scripts. Guaranteed on macOS (ships with Xcode CLT). Validate in HookManager and warn if missing.

## Verification
1. `make build` — compiles without errors
2. `make run` — menu bar icon appears, discovers real running Claude sessions
3. `make test` — all unit tests pass
4. `make format` — code is formatted
5. Manual: see this VS Code Claude session appear with correct project, model, context %, cost
6. Manual: complete a task in a Claude session → status changes to "waiting" (amber)
7. Manual: send a new message → status changes back to "working" (green)
8. Manual: expand a session row → see detail grid with real data
9. Manual: verify light + dark mode
