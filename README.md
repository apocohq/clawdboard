# Clawdboard

Native macOS menu bar app for monitoring Claude Code agent sessions in real time.

> **Warning** This project is under active development, created with heavy AI assistance. Use at your own risk.

## Get Started

```bash
git clone https://github.com/apoco-labs/clawdboard.git
cd clawdboard
```

Then open Claude Code and run:

```
/setup-clawdboard
```

This builds the app, installs it, configures hooks, and sets up your IDE integration (iTerm2 or VS Code) — all in one go.

See the **[Setup Guide](docs/SETUP.md)** for details on what gets configured and manual setup instructions.

## Features

- Real-time session monitoring via Claude Code hooks
- Status indicators: working, waiting, needs approval, abandoned
- Context window usage tracking (percentage)
- Model and git branch display
- "Focus in iTerm2" — switch to the exact terminal pane
- "Focus in VS Code" — open the correct workspace window
- "Focus in JetBrains" — open the project and activate the Terminal panel
- Native macOS tabs support for VS Code
- Remote host monitoring via SSH
- Session auto-cleanup for stale/crashed sessions

## Development

Requires: Swift 6 toolchain, [mise](https://mise.jdx.dev/)

```bash
mise run setup     # Install tools and git hooks
mise run build     # swift build
mise run run       # swift run Clawdboard
mise run test      # swift test
mise run format    # Auto-fix formatting
mise run lint      # Check formatting + lint
```

### Watch Mode

To run the app with auto-restart on every code change:

```bash
mise run dev
```

See [CLAUDE.md](CLAUDE.md) for architecture details and conventions.
