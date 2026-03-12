# Clawdboard

Native macOS menu bar app (SwiftUI) for monitoring Claude Code agent sessions.

## Build & Run

```bash
make setup    # Install tools (mise) and git hooks
make build    # swift build
make run      # swift run Clawdboard
make test     # swift test
make format   # Auto-fix formatting
make lint     # Check formatting + lint
```

## Tooling

- **mise** manages tool versions and dev tasks. Define new workflow commands as `[tasks.*]` in `.mise.toml`, not as raw shell scripts.
- **swift-format** (Apple's, bundled with Swift toolchain) is the authoritative formatter. Config in `.swift-format`.
- **swiftlint** for additional lint rules. Config in `.swiftlint.yml` — rules are tuned to not conflict with swift-format.
- **Pre-commit hook** runs `mise run pre-commit` (swift-format + swiftlint on staged files). Generated via `mise generate git-pre-commit --write`.

## Architecture

- **SPM library + executable split**: `ClawdboardLib` (all code) + `Clawdboard` (thin `@main` entry point) + `ClawdboardTests` (imports ClawdboardLib). This is required because SPM executable targets can't be imported by test targets.
- **Swift 5 language mode** in Swift 6 toolchain (avoids strict concurrency fights for a PoC).
- **Hooks-first session discovery**: Claude hooks write state files to `~/.clawdboard/sessions/`. The Swift app just reads JSON — all JSONL parsing, cost calculation, and token counting happens in the hook script (`hooks/clawdboard-hook.sh`).
- **Single `@Observable` AppState** owned by the App struct, distributed via `.environment()`.
- **3s debounce** on `Stop` hook (pending_waiting -> waiting). **30s staleness** heuristic for interrupted sessions.

## Key Paths

- `hooks/clawdboard-hook.sh` — bash+python3 script installed as Claude hook
- `Sources/ClawdboardLib/` — all library code (models, state, views, discovery)
- `Sources/Clawdboard/ClawdboardApp.swift` — app entry point
- `scripts/bundle.sh` — creates `.app` bundle from release binary
