<div align="center">

# Clawdboard

### Mission Control for AI Agents

**Every idle agent is wasted capacity.**

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/platform-macOS-black.svg)]()
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)]()
[![GitHub stars](https://img.shields.io/github/stars/apocohq/clawdboard?style=social)](https://github.com/apocohq/clawdboard/stargazers)

<!-- 🚀 Product Hunt badge goes here after launch -->

</div>

<p align="center"><img src="assets/demo.gif" width="640" alt="Clawdboard demo" /></p>

---

You're running five agents. One needs approval. Two are stuck. **Clawdboard sits in your menu bar and shows you which Claude Code session needs your attention.** One click and you're there.

<table align="center">
<tr><th>Agents in your workflow</th><th>Need Clawdboard?</th></tr>
<tr><td>1–2</td><td>Probably not (yet)</td></tr>
<tr><td>3–5</td><td>Yes</td></tr>
<tr><td>5+</td><td>Yesterday</td></tr>
</table>

## What Clawdboard Solves

**See everything at a glance**
- Status for every session: working, waiting, needs approval, abandoned
- Context window usage: know when an agent is running hot
- Model and git branch display

**Get there in one click**
- Focus in iTerm2: jumps to the exact terminal pane
- Focus in VS Code: opens the right workspace window
- Focus in JetBrains: opens the project, activates terminal

**Works how you work**
- Remote host monitoring via SSH
- Auto-cleanup of stale and crashed sessions
- Native macOS: menu bar, not a browser tab

## Get started

Open Claude Code and run these commands:

```
/plugins marketplace add apocohq/claude-plugins
/plugins install clawdboard@apoco-plugins
/reload-plugins
/clawdboard:install
```

That's it. Installs the app via Homebrew, configures hooks, and sets up your IDE integration.

*Yes, you use Claude Code to set up your Claude Code manager. We know.*

> See the [Setup Guide](docs/SETUP.md) for details on what gets configured and manual installation.

## How it works

Clawdboard uses Claude Code's [hooks system](https://docs.anthropic.com/en/docs/claude-code/hooks) to receive real-time session events. No polling, no screen scraping, no daemon. Just hooks.

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

See [CLAUDE.md](CLAUDE.md) for architecture details and conventions.

### Watch Mode

To run the app with auto-restart on every code change:

```bash
mise run dev
```

## Contributing

We're building fast. If you're into Swift, macOS dev, or just want better agent tooling: [PRs welcome](https://github.com/apocohq/clawdboard/issues).

## Star this repo ⭐

You'll get notified when we ship updates. We're shipping a lot.

## Built with

Swift 6 · SwiftUI · macOS native · [Claude Code Hooks API](https://docs.anthropic.com/en/docs/claude-code/hooks)

---

<div align="center">

MIT License · [Website](https://clawdboard.dev) · Built for [Claude Code](https://claude.ai/code)

</div>
