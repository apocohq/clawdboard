# Clawdboard Design Manual

Component catalog documenting the visual language of the Clawdboard menu bar panel.
Use this as a reference when making UI changes, discussing design, or onboarding contributors.

Icons follow [Apple's SF Symbols HIG](https://developer.apple.com/design/human-interface-guidelines/sf-symbols). Prefer outlined variants for actions, filled for status indicators. Match symbol weight to adjacent text.

## Overview

- **Type**: macOS menu bar panel (+ optional detached floating window)
- **Width**: 420pt fixed
- **Theme**: Inherits system appearance (light/dark) via semantic SwiftUI colors
- **Design philosophy**: Compact, information-dense, monospaced for technical data

## Color System

All colors are semantic SwiftUI values — they adapt automatically to light/dark mode.

### Status Colors

| Status | Color | Used in |
|--------|-------|---------|
| Working / Pending | `.green` | StatusDot, StatusPill, subagent dots, menu bar dot |
| Approval | `.red` | StatusDot, StatusPill, menu bar dot |
| Waiting | `.orange` | StatusDot, StatusPill, menu bar dot |
| Idle (abandoned) | `.gray` at 40% opacity | StatusDot |
| Unknown | `.gray` | StatusDot |

> **Accessibility**: Red and green are indistinguishable for ~8% of men with color vision deficiency. The critical working/approval distinction does not rely on color alone — approval is the only pulsing state, and the text label in the metadata line provides a third signal. Do not add pulsing to other states without providing an alternative non-color differentiator.

### Usage Gauge Colors

All usage indicators (context bar, usage progress bar) share the same color scale and thresholds:

| Range | Color | Meaning |
|-------|-------|---------|
| 0–69% | `.blue` | Healthy |
| 70–89% | `.orange` | Elevated — worth noting |
| 90%+ | `.red` | Critical — action likely needed |

Applied to: ContextBar (horizontal, per-session context window), UsageWindowView (horizontal, account usage limits).

### Text Hierarchy

| Level | Style | Use |
|-------|-------|-----|
| Primary | `.primary` (implicit) | Session titles, app title |
| Secondary | `.secondary` | Metadata, labels, action icons, section headers |
| Tertiary | `.tertiary` | Timestamps, empty state, refresh tooltip |

### Backgrounds

| Element | Color |
|---------|-------|
| Gauge tracks (bar) | `.quaternary` |
| Session row | `.quaternary` at 50% opacity |
| Status pill | Status color at 12% opacity |

---

## Components

### Menu Bar Label
**File**: `Sources/Clawdboard/ClawdboardApp.swift`

The menu bar icon adapts based on session state:

**Idle (no active sessions)**: `apple.terminal` SF Symbol (template mode). If usage is above threshold, shows a usage ring instead.

**Active sessions**: One colored dot per session, ordered by urgency (red → orange → green). No text, no icons — just dots.

| Property | Value |
|----------|-------|
| Dot size | 8pt diameter |
| Dot spacing | 4pt between dots |
| Max dots | 8 (capped) |
| Dot colors | `.systemRed` (approval), `.systemOrange` (waiting), `.systemGreen` (working) |
| Template mode | `false` when dots shown (preserves color) |
| Usage ring | 14pt diameter, 2.5pt stroke, appended after dots if above threshold |

---

### StatusDot
**File**: `Sources/ClawdboardLib/Views/Components.swift`

Colored circle indicating session status.

| Property | Value |
|----------|-------|
| Size | 8×8pt |
| Shape | Filled `Circle()` |

Colors follow the Status Colors table. Only approval status pulses (opacity 1.0↔0.4, 1s ease-in-out, repeats forever) — reserving the animation as an attention signal for user action required. All other states are static.

---

### StatusPill
**File**: `Sources/ClawdboardLib/Views/PanelView.swift`

Header summary badges showing counts by status.

| Property | Value |
|----------|-------|
| Shape | `Capsule()` |
| Background | Status color at 12% opacity |
| Dot size | 6×6pt filled circle |
| Dot-to-text spacing | 3pt |
| Pill-to-pill spacing | 6pt |
| Padding | 6pt horizontal, 2pt vertical |
| Text font | `.caption2` |
| Labels | "N approval" (red), "N waiting" (orange), "N working" (green) |

Only shown when count > 0 for that status.

---

### ContextBar
**File**: `Sources/ClawdboardLib/Views/Components.swift`

Horizontal progress bar showing context window usage.

| Property | Value |
|----------|-------|
| Height | 4pt |
| Corner radius | 2pt |
| Track color | `.quaternary` |
| Fill width | Proportional to percentage (capped at 100%) |

**Fill color**: Uses the shared usage gauge color scale (see Color System).

---

### UsageWindowView (Progress Bar)
**File**: `Sources/ClawdboardLib/Views/Components.swift`

Horizontal progress bar for account usage limits.

| Property | Value |
|----------|-------|
| Bar height | 8pt |
| Corner radius | 2pt |
| Track color | `.quaternary` |
| Fill width | Proportional to utilization (capped at 100%) |
| Estimated marker | 1pt wide vertical line, `.primary` at 40% opacity, 8pt tall, positioned at estimated % |

**Bar color**: Uses the shared usage gauge color scale (see Color System).

**Layout** (VStack, 3pt spacing):
- Header row: Percentage in `.caption.monospacedDigit().weight(.semibold)`, bar color | Spacer | Window label ("5h" / "7d") in `.caption.weight(.semibold)`, `.secondary`
- Progress bar with estimated marker overlay
- Footer row: Estimated usage (`est N%`) in `.caption2.monospacedDigit()`, `.secondary` | Spacer | Reset time in `.caption2.monospacedDigit()`, `.tertiary`

Two windows side by side in an HStack with 24pt spacing.

---

### AgentRow
**File**: `Sources/ClawdboardLib/Views/AgentRow.swift`

Single session row with expand/collapse.

| Property | Value |
|----------|-------|
| Row padding | 6pt vertical, 8pt horizontal |
| Background | `.quaternary.opacity(0.5)`, 6pt corner radius |
| Element spacing | 8pt (HStack) |
| Expand animation | 0.15s ease-in-out |
| Fallback opacity | 0.6 — non-hook-tracked sessions are visually dimmed to signal incomplete data |

**Layout**: `StatusDot` | Title + metadata (VStack) | Spacer | Action buttons + context %

**Title**: `.system(.body, weight: .medium)` — monospaced design when showing project path, proportional when showing first prompt. Single line, truncated.

**Metadata line**: `.caption`, `.secondary`, dot-separated. Order: remote host icon + name, status label (first), model, branch, idle time, subagent count. All items use `.secondary` — the StatusDot already communicates state via color.

**Action buttons** (right side, HStack spacing 0):
- Focus iTerm2: `apple.terminal` at `.body`, `.secondary`
- Focus VS Code: `macwindow` at `.body`, `.secondary`
- All buttons: 28×28pt hit target, `.plain` style, pointing hand cursor on hover

**Context percentage**: `.caption2.monospacedDigit()`, 32pt wide trailing-aligned. Color follows the usage gauge color scale when elevated, otherwise `.secondary`. Shows "—" in `.tertiary` if not hook-tracked.

**Expanded details** (below main row):
- Divider with 2pt vertical padding
- Context bar row: label (60pt) + bar + percentage
- DetailRow entries: Host, Model, Branch, Session, Uptime, Path
- Subagents section: "Agents" label (60pt, trailing-aligned) + green 5×5pt dots, agent type, truncated ID — aligned with DetailRow labels
- "Restart session for full tracking" warning in `.caption2`, `.orange` (if not hook-tracked)
- Delete button: `trash` icon in `.caption`, `.tertiary`, 28×28pt hit target, right-aligned — shown for deletable sessions (hidden in collapsed row to prevent accidental clicks)

---

### DetailRow
**File**: `Sources/ClawdboardLib/Views/Components.swift`

Key-value pair in expanded detail grid.

| Property | Value |
|----------|-------|
| Label width | 60pt, trailing-aligned |
| Label font | `.caption`, `.secondary` |
| Value font | `.caption.monospaced()` |
| Truncation | Single line, middle truncation |

---

### Section Headers (Collapsible)
**File**: `Sources/ClawdboardLib/Views/SessionsTab.swift`

Group headers for sessions by project name. For GitHub repos, the org prefix is stripped (e.g., "acme/my-app" → "MY-APP"). Tapping the header toggles collapse/expand of the group.

| Property | Value |
|----------|-------|
| Font | `.caption.weight(.semibold)` |
| Color | `.secondary` |
| Case | `.uppercase` |
| Padding | 8pt leading, 4pt trailing, 10pt top (except first group) |
| Chevron | `chevron.right` (collapsed) / `chevron.down` (expanded), 8pt system, `.semibold`, `.tertiary` |
| Chevron-to-text spacing | 4pt |
| Collapse animation | 0.15s ease-in-out |
| Session count badge | Shown when collapsed, `.caption2.monospacedDigit()`, `.tertiary`, trailing |

---

### Panel Header
**File**: `Sources/ClawdboardLib/Views/PanelView.swift`

| Element | Spec |
|---------|------|
| Title | "Clawdboard" in `.headline` |
| Alignment | `.firstTextBaseline` |
| Status pills | Right-aligned, 6pt spacing |
| Padding | 12pt horizontal, 10pt top, 6pt bottom |

---

### Panel Footer
**File**: `Sources/ClawdboardLib/Views/PanelView.swift`

| Element | Spec |
|---------|------|
| Session count | `.caption`, `.secondary` |
| Detach toggle | `.checkbox`, `.controlSize(.small)` |
| Refresh button | `arrow.clockwise` icon, `.caption`, `.secondary` — tooltip shows "Usage updated N ago" |
| Settings menu | `gearshape` icon, `.caption`, `.secondary`, no menu indicator |
| Padding | 12pt horizontal, 8pt vertical |

---

### Empty State
**File**: `Sources/ClawdboardLib/Views/PanelView.swift`

Shown when no sessions exist.

| Element | Spec |
|---------|------|
| Icon | `apple.terminal` SF Symbol, `.title2`, `.tertiary` |
| Title | "No active sessions", `.subheadline`, `.secondary` |
| Subtitle | "Start a Claude Code session to see it here", `.caption`, `.tertiary` |
| Spacing | 6pt between elements |
| Padding | 24pt vertical |

---

## Layout Constants

| Constant | Value |
|----------|-------|
| Panel width | 420pt |
| Header padding | 12pt H, 10pt top, 6pt bottom |
| Footer padding | 12pt H, 8pt V |
| Usage limits padding | 12pt H, 8pt V |
| Stats-to-sessions gap | 8pt (Spacer below usage limits) |
| Sessions scroll top padding | 10pt (inside ScrollView) |
| Sessions scroll fade | 8pt linear gradient mask (clear → black) at top |
| Sessions list padding | 8pt H, 10pt top, 4pt bottom |
| Session group spacing | 4pt (VStack) |
| Inter-group gap | 10pt top padding |
| Usage windows spacing | 24pt between bars (HStack) |

---

## Icons (SF Symbols)

| Icon | Use | Size/Style |
|------|-----|------------|
| `apple.terminal` | Empty state, menu bar idle | `.title2` |
| `apple.terminal` | Focus iTerm2 | `.body` |
| `macwindow` | Focus VS Code / IDE | `.body` |
| `trash` | Delete session (expanded detail) | `.caption` |
| `chevron.right` / `chevron.down` | Section collapse toggle | 8pt system, `.semibold` |
| `network` | Remote host indicator | `.caption2` |
| `gearshape` | Settings menu | `.caption` |
| `arrow.clockwise` | Refresh usage (footer) | `.caption` |
| `checkmark.circle.fill` | Hooks installed (green) | Settings |
| `xmark.circle` | No hooks (orange) | Settings |
| `exclamationmark.triangle` | SSH error (red) | Settings |
| `questionmark.circle` | Unchecked host (gray) | Settings |
| `plus` | Add remote host | Settings |
| `pencil` | Edit remote host | Settings |
| `trash` | Delete remote host | Settings |

---

## Typography Scale

| Use | Font Spec | Notes |
|-----|-----------|-------|
| App title | `.headline` | "Clawdboard" in header |
| Session title | `.body` weight `.medium` | Monospaced design for paths, proportional for prompts |
| Metadata | `.caption` | Dot-separated, `.secondary` |
| Small labels | `.caption2` | Context %, pill text |
| Technical data | `.caption.monospaced()` | Paths, session IDs, detail values |
| Numeric data | `.monospacedDigit()` | Percentages, timing, counters |
| Usage percentage | `.caption.monospacedDigit().weight(.semibold)` | Bar header |
| Window label | `.caption.weight(.semibold)` | "5h", "7d" |
| Empty state icon | `.title2` | SF Symbol |
| Empty state title | `.subheadline` | |

---

## Animations

| Animation | Duration | Curve | Details |
|-----------|----------|-------|---------|
| StatusDot pulse | 1.0s | ease-in-out | Opacity 1.0↔0.4, repeats forever. Active for approval only. |
| Row expand/collapse | 0.15s | ease-in-out | Bound to `isExpanded` state |
| Group collapse/expand | 0.15s | ease-in-out | Bound to `collapsedGroups` state |

---

## Session Sort Order

Sessions are sorted by urgency (most attention-needed first):

1. **Approval** (sort order 0)
2. **Waiting** (sort order 1)
3. **Pending/Working** (sort order 2–3)
4. **Unknown** (sort order 4)
5. **Idle/Abandoned** (sort order 5)

Within each status group, sessions are grouped alphabetically by GitHub repo slug (or project name for local repos), displayed as uppercase section headers.
