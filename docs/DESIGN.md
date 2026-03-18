# Clawdboard Design Manual

Component catalog documenting the visual language of the Clawdboard menu bar panel.
Use this as a reference when making UI changes, discussing design, or onboarding contributors.

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
| Working / Pending | `.green` | StatusDot, StatusPill, subagent dots |
| Needs Approval | `.red` | StatusDot, StatusPill |
| Waiting | `.orange` | StatusDot, StatusPill |
| Idle (abandoned) | `.gray` at 40% opacity | StatusDot |
| Unknown | `.gray` | StatusDot |

> **Accessibility**: Red and green are indistinguishable for ~8% of men with color vision deficiency. The critical working/approval distinction does not rely on color alone — needs approval is the only pulsing state, and the text label in the metadata line provides a third signal. Do not add pulsing to other states without providing an alternative non-color differentiator.

### Usage Gauge Colors

All usage indicators (context bar, ring gauge) share the same color scale and thresholds:

| Range | Color | Meaning |
|-------|-------|---------|
| 0–69% | `.green` | Healthy |
| 70–89% | `.orange` | Elevated — worth noting |
| 90%+ | `.red` | Critical — action likely needed |

Applied to: ContextBar (horizontal, per-session context window), RingGauge (circular, account usage limits).

### Text Hierarchy

| Level | Style | Use |
|-------|-------|-----|
| Primary | `.primary` (implicit) | Session titles, app title |
| Secondary | `.secondary` | Metadata, labels, action icons, section headers |
| Tertiary | `.tertiary` | Timestamps, empty state, refresh/update text |

### Backgrounds

| Element | Color |
|---------|-------|
| Gauge tracks (bar + ring) | `.quaternary` |
| Expanded row | `.quaternary` at 50% opacity |
| Status pill | Status color at 12% opacity |

---

## Components

### StatusDot
**File**: `Sources/ClawdboardLib/Views/Components.swift`

Colored circle indicating session status.

| Property | Value |
|----------|-------|
| Size | 8×8pt |
| Shape | Filled `Circle()` |

Colors follow the Status Colors table. Only `.needsApproval` pulses (opacity 1.0↔0.4, 1s ease-in-out, repeats forever) — reserving the animation as an attention signal for user action required. All other states are static.

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

### RingGauge (UsageWindowView)
**File**: `Sources/ClawdboardLib/Views/Components.swift`

Circular progress ring for account usage limits.

| Property | Value |
|----------|-------|
| Size | 36×36pt |
| Stroke width | 3pt |
| Line cap | `.round` |
| Track color | `.quaternary` |
| Rotation | −90° (starts at 12 o'clock) |
| Center text | `"%.0f%%"` in `.system(size: 10, weight: .semibold, design: .monospaced)` |

**Ring color**: Uses the shared usage gauge color scale (see Color System).

**Metrics alongside** (VStack, 1pt spacing):
- Window label ("5h" / "7d") — `.caption.weight(.semibold)`, `.secondary`
- Estimated usage — `.caption.monospacedDigit()`, `.secondary`
- Reset time — `.caption.monospacedDigit()`, `.tertiary`

Two windows separated by a `Divider().frame(height: 44)`, 12pt spacing between them.

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

**Metadata line**: `.caption`, `.secondary`, dot-separated. Contains: remote host icon + name, model, branch, status label, idle time, subagent count. The status label uses its status color (red/orange/green) instead of `.secondary` to stand out from ambient metadata.

**Action buttons** (right side, HStack spacing 0):
- Delete: `xmark.circle.fill` at 13pt, `.tertiary` — only for abandoned sessions
- Focus iTerm2: `terminal` at `.body`, `.secondary`
- Focus VS Code: `curlybraces` at `.body`, `.secondary`
- All buttons: 28×28pt hit target, `.plain` style, pointing hand cursor on hover

**Context percentage**: `.caption2.monospacedDigit()`, 32pt wide trailing-aligned. Color follows the usage gauge color scale when elevated, otherwise `.secondary`. Shows "—" in `.tertiary` if not hook-tracked.

**Expanded details** (below main row):
- Divider with 2pt vertical padding
- Context bar row: label (60pt) + bar + percentage
- DetailRow entries: Host, Model, Branch, Session, Uptime, Path
- Subagents section (if any): green 5×5pt dots, agent type, truncated ID
- "Restart session for full tracking" warning in `.caption2`, `.orange` (if not hook-tracked)

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

### Section Headers
**File**: `Sources/ClawdboardLib/Views/SessionsTab.swift`

Group headers for sessions by project name. For GitHub repos, the org prefix is stripped (e.g., "acme/my-app" → "MY-APP").

| Property | Value |
|----------|-------|
| Font | `.caption.weight(.semibold)` |
| Color | `.secondary` |
| Case | `.uppercase` |
| Padding | 4pt horizontal, 6pt top (except first group) |

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
| Settings menu | `gearshape` icon, `.caption`, `.secondary`, no menu indicator |
| Padding | 12pt horizontal, 8pt vertical |

---

### Empty State
**File**: `Sources/ClawdboardLib/Views/PanelView.swift`

Shown when no sessions exist.

| Element | Spec |
|---------|------|
| Icon | `terminal` SF Symbol, `.title2`, `.tertiary` |
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
| Sessions list padding | 8pt H, 4pt V |
| Session group spacing | 4pt (VStack) |
| Inter-group gap | 6pt top padding |
| Usage windows spacing | 12pt between gauges |
| Usage window divider | 44pt height |

---

## Icons (SF Symbols)

| Icon | Use | Size/Style |
|------|-----|------------|
| `terminal` | Empty state | `.title2` |
| `terminal` | Focus iTerm2 | `.body` |
| `curlybraces` | Focus VS Code | `.body` |
| `xmark.circle.fill` | Delete session | 13pt system |
| `network` | Remote host indicator | `.caption2` |
| `gearshape` | Settings menu | `.caption` |
| `arrow.clockwise` | Refresh usage | `.caption` |
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
| Ring gauge center | `.system(size: 10, weight: .semibold, design: .monospaced)` | Usage percentage |
| Window label | `.caption.weight(.semibold)` | "5h", "7d" |
| Empty state icon | `.title2` | SF Symbol |
| Empty state title | `.subheadline` | |

---

## Animations

| Animation | Duration | Curve | Details |
|-----------|----------|-------|---------|
| StatusDot pulse | 1.0s | ease-in-out | Opacity 1.0↔0.4, repeats forever. Active for needs approval only. |
| Row expand/collapse | 0.15s | ease-in-out | Bound to `isExpanded` state |

---

## Session Sort Order

Sessions are sorted by urgency (most attention-needed first):

1. **Needs Approval** (sort order 0)
2. **Waiting** (sort order 1)
3. **Pending/Working** (sort order 2–3)
4. **Unknown** (sort order 4)
5. **Idle/Abandoned** (sort order 5)

Within each status group, sessions are grouped alphabetically by GitHub repo slug (or project name for local repos), displayed as uppercase section headers.
