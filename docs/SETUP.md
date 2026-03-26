# Getting the Most Out of Clawdboard

Clawdboard monitors your Claude Code sessions from the macOS menu bar. The easiest way to set everything up is to open Claude Code and run:

```
/plugins marketplace add apocohq/claude-plugins
/plugins install clawdboard@apoco-plugins
/clawdboard:install
```

This installs the app via Homebrew, configures hooks, and sets up your IDE — all automatically.

The rest of this document explains what gets configured and how to do it manually.

---

## How It Works

Clawdboard uses Claude Code **hooks** to track session state. Each hook event (session start, tool use, stop, etc.) triggers a Python script that writes a JSON state file to `~/.clawdboard/sessions/`. The menu bar app watches that directory and displays live status.

On top of that, there are two IDE-specific integrations that enable the "Focus" button — jumping from Clawdboard directly to the right window/pane.

## Pathway 1: Terminal + iTerm2

### What You Get

- Real-time session status in the menu bar
- Context window usage, model, and git branch
- **"Focus in iTerm2"** — switches to the exact pane running that session, even in split panes

### Manual Setup

1. **Enable iTerm2 Python API**: iTerm2 → Settings → General → Magic → Enable Python API

2. **Install integration scripts** (from the repo):
   ```bash
   mkdir -p ~/.config/iterm2/AppSupport/Scripts/AutoLaunch
   cp Sources/ClawdboardLib/Resources/iterm2-integration.py \
      ~/.config/iterm2/AppSupport/Scripts/AutoLaunch/clawdboard.py
   cp Sources/ClawdboardLib/Resources/iterm2-focus.py \
      ~/.clawdboard/iterm2-focus.py
   chmod 755 ~/.config/iterm2/AppSupport/Scripts/AutoLaunch/clawdboard.py \
             ~/.clawdboard/iterm2-focus.py
   ```

   Or install from Clawdboard's Settings: **iTerm2 Integration → Install**.

3. **Restart iTerm2** so it picks up the AutoLaunch script.

### How It Works

The AutoLaunch script runs in the background inside iTerm2, polling `~/.clawdboard/sessions/` every 2 seconds. It matches Claude Code processes to iTerm2 panes by walking the process tree, then writes the pane UUID back into the session file. The "Focus" button uses AppleScript to select that pane.

---

## Pathway 2: VS Code + Native macOS Tabs

### What You Get

- Real-time session status in the menu bar
- Context window usage, model, and git branch
- **"Focus in VS Code"** — opens the correct workspace window
- **Native macOS tabs** — manage multiple Claude Code windows as tabs in one window

### Manual Setup

1. **Install the `code` CLI**: In VS Code, **Cmd+Shift+P → "Shell Command: Install 'code' command in PATH"**
   (For Cursor: `cursor`. For Insiders: `code-insiders`.)

2. **Enable native macOS tabs**: Add to VS Code settings (`Cmd+Shift+P → Preferences: Open User Settings (JSON)`):
   ```json
   "window.nativeTabs": true
   ```
   Restart VS Code after changing this.

3. **No additional hook setup needed** — the Claude Code VS Code extension automatically creates lock files that Clawdboard reads.

### How It Works

The Claude Code extension writes lock files to `~/.claude/ide/` with workspace folders and PID. Clawdboard matches each session's working directory to the most specific workspace folder. The "Focus" button runs `code <workspace-path>` to bring the correct window forward. Native macOS tabs let you merge all VS Code windows into one tabbed window (**Window → Merge All Windows**).

---

## Troubleshooting

**Sessions not appearing**: Hooks load at session start — restart running Claude Code sessions. Check `~/.claude/settings.json` has entries containing "clawdboard".

**"Focus in iTerm2" missing**: Check Python API is enabled (Settings → General → Magic). Restart iTerm2 after installing scripts.

**"Focus in VS Code" missing**: Check `code --version` works in terminal. Make sure Claude Code is running inside VS Code, not a standalone terminal.

**Native tabs not working**: Restart VS Code after setting `"window.nativeTabs": true`. Use **Window → Merge All Windows** to combine existing windows.
