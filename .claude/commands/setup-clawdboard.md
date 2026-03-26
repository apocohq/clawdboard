# Setup Clawdboard

You are setting up Clawdboard for this user. Clawdboard is a macOS menu bar app that monitors Claude Code sessions. This skill handles everything: building the app, installing hooks, and configuring IDE integration.

## Phase 1: Detect Current State

Run these checks and report results as a compact summary:

1. **Clawdboard app**: Check if `Clawdboard.app` exists in `~/Applications/` or `/Applications/`
2. **Hooks installed**: Read `~/.claude/settings.json` and check if any hook commands contain "clawdboard"
3. **Hook script**: Check if `~/.clawdboard/hooks/clawdboard-hook.py` exists
4. **iTerm2**: Check if `/Applications/iTerm.app` exists
5. **iTerm2 Python API**: Run `defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null` (1 = enabled)
6. **iTerm2 scripts**: Check if `~/.config/iterm2/AppSupport/Scripts/AutoLaunch/clawdboard.py` exists
7. **VS Code**: Check if `/Applications/Visual Studio Code.app` exists
8. **VS Code CLI**: Run `which code 2>/dev/null`
9. **VS Code native tabs**: Read `~/Library/Application Support/Code/User/settings.json` and check for `"window.nativeTabs": true`
10. **Swift toolchain**: Run `swift --version 2>/dev/null` to check if Swift is available for building
11. **mise**: Run `which mise 2>/dev/null` to check if mise is available

Present the results, then move to Phase 2.

## Phase 2: Ask Which Pathway

Based on what IDEs are available, ask the user which pathway to set up:

- **Terminal + iTerm2** — enables "Focus in iTerm2" button (switches to exact terminal pane)
- **VS Code Extension** — enables "Focus in VS Code" button + native macOS tabs for session management
- **Both** — if both IDEs are available

Only offer pathways for IDEs that are actually installed.

## Phase 3: Backup Settings

Before making ANY changes:

1. If `~/.claude/settings.json` exists, copy it to `~/.claude/settings.json.backup.$(date +%Y%m%d%H%M%S)`
2. If modifying VS Code settings, copy `~/Library/Application Support/Code/User/settings.json` to `~/Library/Application Support/Code/User/settings.json.backup.$(date +%Y%m%d%H%M%S)`

Tell the user what was backed up.

## Phase 4: Build & Install App

If Clawdboard.app is not already installed:

1. If `mise` is available, run `mise run setup` first to ensure tools are installed
2. Run `./scripts/bundle.sh` from the repo root — this builds a release binary and creates `Clawdboard.app`
3. Copy `Clawdboard.app` to `~/Applications/` (create the directory if needed): `cp -r Clawdboard.app ~/Applications/`
4. Launch it: `open ~/Applications/Clawdboard.app`

If already installed, skip this phase but still update the hook script (Phase 5 handles this).

## Phase 5: Install Hooks & Scripts

### Common Steps (both pathways)

1. Create directories:
   ```
   mkdir -p ~/.clawdboard/hooks
   mkdir -p ~/.clawdboard/sessions
   ```

2. Copy the hook script from this repo:
   ```
   cp Sources/ClawdboardLib/Resources/clawdboard-hook.py ~/.clawdboard/hooks/clawdboard-hook.py
   chmod 755 ~/.clawdboard/hooks/clawdboard-hook.py
   ```

3. Merge hooks into `~/.claude/settings.json`. Read the existing file (or start with `{}`), then ensure the `hooks` key contains entries for ALL of these events:

   **Standard events** (each gets a wildcard matcher):
   `SessionStart`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop`, `UserPromptSubmit`, `SessionEnd`, `SubagentStart`, `SubagentStop`

   Each standard event entry looks like:
   ```json
   {
     "matcher": "*",
     "hooks": [{"type": "command", "command": "python3 ~/.clawdboard/hooks/clawdboard-hook.py", "timeout": 10}]
   }
   ```

   **Notification events** (two separate matchers added to a `Notification` array):
   ```json
   {"matcher": "idle_prompt", "hooks": [{"type": "command", "command": "python3 ~/.clawdboard/hooks/clawdboard-hook.py idle_prompt", "timeout": 10}]}
   ```
   ```json
   {"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "python3 ~/.clawdboard/hooks/clawdboard-hook.py permission_prompt", "timeout": 10}]}
   ```

   **IMPORTANT**: Preserve any existing hooks that don't contain "clawdboard" in their command. Remove existing clawdboard hooks first (to avoid duplicates), then append new ones. When merging JSON, use `python3 -c` or `jq` if available. Do NOT use sed/awk for JSON manipulation.

### iTerm2 Pathway

4. Copy iTerm2 scripts:
   ```
   mkdir -p ~/.config/iterm2/AppSupport/Scripts/AutoLaunch
   cp Sources/ClawdboardLib/Resources/iterm2-integration.py ~/.config/iterm2/AppSupport/Scripts/AutoLaunch/clawdboard.py
   chmod 755 ~/.config/iterm2/AppSupport/Scripts/AutoLaunch/clawdboard.py
   cp Sources/ClawdboardLib/Resources/iterm2-focus.py ~/.clawdboard/iterm2-focus.py
   chmod 755 ~/.clawdboard/iterm2-focus.py
   ```

5. Check if iTerm2 Python API is enabled. If NOT:
   - Tell the user: **iTerm2 → Settings → General → Magic → Enable Python API**
   - This cannot be done programmatically

6. If iTerm2 is running, suggest restarting it so the AutoLaunch script picks up.

### VS Code Pathway

4. Check if `code` CLI is in PATH. If NOT:
   - Tell the user: **Cmd+Shift+P → "Shell Command: Install 'code' command in PATH"**

5. Read `~/Library/Application Support/Code/User/settings.json`. If `"window.nativeTabs"` is not set to `true`:
   - Add `"window.nativeTabs": true` (merge, don't overwrite)
   - Tell user to restart VS Code for the change to take effect

## Phase 6: Verify & Summarize

Run verification checks:

1. Clawdboard.app is installed and running
2. `~/.clawdboard/hooks/clawdboard-hook.py` exists and is executable
3. `~/.claude/settings.json` contains all expected hook events
4. For iTerm2: scripts are in place
5. For VS Code: `nativeTabs` is set

Print a clear summary:
- What was installed/configured
- Any manual steps still needed (e.g., enable iTerm2 Python API, install `code` CLI, restart IDE)
- Note that new Claude Code sessions will be tracked automatically; existing sessions need to be restarted

## Notes

- The hook command path uses `~` (not expanded): `python3 ~/.clawdboard/hooks/clawdboard-hook.py`
- All new sessions after setup will be tracked. Existing running sessions won't appear until restarted.
