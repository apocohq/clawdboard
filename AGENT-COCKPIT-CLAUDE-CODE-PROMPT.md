# Clawdboard — macOS Menu Bar App

## What to build

A native macOS menu bar app in SwiftUI called "Clawdboard". It's a developer tool for managing multiple Claude Code agent sessions from a single menu bar dropdown. Think of it as a control plane for AI coding agents.

## Project setup

- Use Swift Package Manager (not .xcodeproj) — create a Package.swift
- Target macOS 14+ (Sonoma) for latest MenuBarExtra features
- Use `.menuBarExtraStyle(.window)` for a full SwiftUI panel dropdown
- Project structure:

```
Clawdboard/
├── Package.swift
└── Sources/
    ├── App/
    │   └── ClawdboardApp.swift        # @main entry, MenuBarExtra
    ├── Models/
    │   └── Models.swift                 # AgentSession, InboxItem, enums
    ├── Services/
    │   └── AgentManager.swift           # @Observable class, session discovery
    │   └── SessionWatcher.swift         # FileManager watcher for ~/.claude/
    ├── Views/
    │   ├── ClawdboardPanel.swift           # Main dropdown panel
    │   ├── MenuBarLabel.swift           # The icon + status dots in menu bar
    │   ├── SessionsTab.swift            # List of agent sessions
    │   ├── InboxTab.swift               # Context inbox with drop zone
    │   ├── SettingsView.swift           # Settings window (⌘,)
    │   └── Components/
    │       ├── AgentRow.swift           # Single session row (expandable)
    │       ├── ContextBar.swift         # Thin context usage progress bar
    │       ├── StatusDot.swift          # Pulsing colored status indicator
    │       └── InboxItemRow.swift       # Single inbox item row
    └── Utilities/
        └── Extensions.swift             # Color, Date helpers
```

## Core features to implement

### 1. Menu Bar Icon (MenuBarLabel.swift)
- SF Symbol terminal icon (`terminal.fill` or custom)
- Colored dots next to it showing aggregate status:
  - Green dot if any agent is working
  - Yellow dot if any agent is waiting for input
  - Red dot if any agent has errored
- Agent count number next to dots
- The dots should subtly pulse (use `.animation(.easeInOut(duration: 2).repeatForever())`)

### 2. Dropdown Panel (ClawdboardPanel.swift)
- Fixed width ~380pt, vibrancy material background (`.ultraThinMaterial`)
- Header showing:
  - "Clawdboard" title + version badge
  - Total cost today (right-aligned, yellow/gold color)
  - Status summary pills (e.g. "2 working", "1 waiting", "1 error")
- Segmented picker for tabs: Sessions | Context Inbox
- Footer with "+ New Session", "Settings" links and ⌘⇧A shortcut hint

### 3. Sessions Tab (SessionsTab.swift)
- Two sections: "Active" and "Idle"
- Sorted by urgency: errors first, then waiting, then working, then idle
- Each row (AgentRow.swift) shows:
  - Status dot (color-coded, pulsing for active states)
  - Session name in monospace font
  - Elapsed time (right-aligned, dim)
  - Last action text (one line, truncated, color-tinted for errors/warnings)
  - Context usage bar (thin 3pt bar: green < 60%, yellow 60-80%, red > 80%)
  - Context % number next to bar
- Clicking a row expands it to show:
  - 2-column grid: Task, Branch, Model, Project, Cost ($), Status
  - Action buttons: "Approve" (yellow, for waiting), "Retry" (red, for error), "Open Terminal", "Stop"
  - Use `.disclosureGroupStyle` or manual expand/collapse with animation

### 4. Agent Manager (AgentManager.swift)
- `@Observable` class that holds `[AgentSession]` and `[InboxItem]`
- For the PoC, populate with mock data (use the data from the JSX reference below)
- Computed properties: `totalCost`, `workingCount`, `waitingCount`, `errorCount`
- Methods: `stopAgent(_:)`, `retryAgent(_:)`, `approveAgent(_:)`
- Timer that simulates live updates (context usage drift, cost increment) for demo

### 5. Future: Session Discovery (SessionWatcher.swift)
- Stub this out with a TODO comment explaining:
  - Watch `~/.claude/projects/` for session JSON files
  - Parse session metadata (status, model, project path)
  - Read `~/.claude/statsig/` or session logs for cost approximation
  - Use `DispatchSource.makeFileSystemObjectSource` for file watching
  - Eventually: shell out to `claude --list` to get active sessions

### 6. Settings (SettingsView.swift)
- Simple form with:
  - Daily budget alert threshold ($)
  - Context usage warning threshold (%)
  - Show/hide idle sessions toggle
  - Keyboard shortcut configuration
  - Claude Code CLI path

## Design guidelines

- Use `.ultraThinMaterial` for the panel background — this gives native macOS vibrancy/blur
- Monospace font for: session names, branch names, costs, context %, model names. Use `.system(.body, design: .monospaced)` 
- System font for everything else
- Colors: use semantic colors where possible, but for status dots use explicit:
  - Working: `Color.green` or `Color(red: 0.2, green: 0.83, blue: 0.6)`
  - Waiting: `Color.yellow` or `Color(red: 0.98, green: 0.75, blue: 0.15)`
  - Error: `Color.red` or `Color(red: 0.97, green: 0.44, blue: 0.44)`
  - Idle: `Color.gray`
- Cost numbers in gold/yellow
- Context bar colors: green default, yellow > 60%, red > 80%
- Keep padding tight — this is a menu bar dropdown, not a full window
- Subtle animations: row expansion, status dot pulse, context bar transitions
- Support both light and dark mode (vibrancy materials handle this mostly)

## Mock data to use

```swift
// Paste these as default values in AgentManager
static let mockSessions: [AgentSession] = [
    AgentSession(
        id: "sess-001", name: "kagenti-auth", project: "kagenti",
        branch: "feat/authbridge-oidc", status: .working,
        task: "Implementing OIDC token exchange flow",
        contextUsage: 0.42, cost: 1.87, model: "opus-4.6",
        lastAction: "Editing src/authbridge/exchange.go",
        startedAt: Date().addingTimeInterval(-252), pid: 12847
    ),
    AgentSession(
        id: "sess-002", name: "agentstack-ci", project: "agentstack",
        branch: "fix/buildkit-cache", status: .waiting,
        task: "Fix BuildKit layer caching in CI pipeline",
        contextUsage: 0.71, cost: 3.42, model: "opus-4.6",
        lastAction: "Waiting: permission to run docker build",
        startedAt: Date().addingTimeInterval(-723), pid: 12901
    ),
    AgentSession(
        id: "sess-003", name: "docs-rewrite", project: "kagenti",
        branch: "chore/api-docs", status: .idle,
        task: "Rewrite API reference for AuthBridge",
        contextUsage: 0.18, cost: 0.54, model: "sonnet-4.6",
        lastAction: "Completed — awaiting new task",
        startedAt: Date().addingTimeInterval(-1800), pid: nil
    ),
    AgentSession(
        id: "sess-004", name: "k8s-scheduler", project: "kagenti",
        branch: "feat/taint-toleration", status: .error,
        task: "Add custom scheduler with taint tolerations",
        contextUsage: 0.89, cost: 5.11, model: "opus-4.6",
        lastAction: "Error: context window near limit after compaction",
        startedAt: Date().addingTimeInterval(-1421), pid: 12955
    ),
    AgentSession(
        id: "sess-005", name: "frontend-dash", project: "agentstack",
        branch: "feat/dashboard-ui", status: .working,
        task: "Build monitoring dashboard components",
        contextUsage: 0.35, cost: 0.92, model: "sonnet-4.6",
        lastAction: "Creating src/components/AgentCard.tsx",
        startedAt: Date().addingTimeInterval(-108), pid: 13002
    ),
]
```

## JSX Prototype Reference

The following React component is a visual prototype of what the app should look like. Use it as a design reference for layout, spacing, colors, and behavior — but implement everything natively in SwiftUI, not as a webview.

Key things to preserve from the prototype:
- The menu bar icon with colored status dots + count
- The dropdown panel width (~380pt) and overall density
- Two-tab layout (Sessions / Context Inbox)
- Agent rows with status dot, name, last action, context bar
- Expandable detail view with 2-column grid + action buttons
- Status pills in the header (colored badges)
- Cost tracking in header
- Context inbox with typed items and drop zone
- Sort order: errors → waiting → working (then idle in separate section)

```jsx
import { useState, useEffect, useRef } from "react";

const AGENTS = [
  {
    id: 1,
    name: "kagenti-auth",
    branch: "feat/authbridge-oidc",
    project: "kagenti",
    status: "working",
    task: "Implementing OIDC token exchange flow",
    contextUsage: 0.42,
    cost: 1.87,
    lastAction: "Editing src/authbridge/exchange.go",
    elapsed: "4m 12s",
    model: "opus-4.6",
  },
  {
    id: 2,
    name: "agentstack-ci",
    branch: "fix/buildkit-cache",
    project: "agentstack",
    status: "waiting",
    task: "Fix BuildKit layer caching in CI pipeline",
    contextUsage: 0.71,
    cost: 3.42,
    lastAction: "Waiting: permission to run docker build",
    elapsed: "12m 03s",
    model: "opus-4.6",
  },
  {
    id: 3,
    name: "docs-rewrite",
    branch: "chore/api-docs",
    project: "kagenti",
    status: "idle",
    task: "Rewrite API reference for AuthBridge",
    contextUsage: 0.18,
    cost: 0.54,
    lastAction: "Completed — awaiting new task",
    elapsed: "—",
    model: "sonnet-4.6",
  },
  {
    id: 4,
    name: "k8s-scheduler",
    branch: "feat/taint-toleration",
    project: "kagenti",
    status: "error",
    task: "Add custom scheduler with taint tolerations",
    contextUsage: 0.89,
    cost: 5.11,
    lastAction: "Error: context window near limit after compaction",
    elapsed: "23m 41s",
    model: "opus-4.6",
  },
  {
    id: 5,
    name: "frontend-dash",
    branch: "feat/dashboard-ui",
    project: "agentstack",
    status: "working",
    task: "Build monitoring dashboard components",
    contextUsage: 0.35,
    cost: 0.92,
    lastAction: "Creating src/components/AgentCard.tsx",
    elapsed: "1m 48s",
    model: "sonnet-4.6",
  },
];

const INBOX_ITEMS = [
  { id: 1, type: "file", name: "auth-flow-diagram.png", project: "kagenti", time: "2m ago" },
  { id: 2, type: "url", name: "OAuth 2.0 Token Exchange RFC", project: null, time: "15m ago" },
  { id: 3, type: "snippet", name: "Error log from staging", project: "agentstack", time: "1h ago" },
  { id: 4, type: "note", name: "Remember: update CLAUDE.md for auth conventions", project: "kagenti", time: "3h ago" },
];

const STATUS_CONFIG = {
  working: { color: "#34D399", label: "Working", pulse: true },
  waiting: { color: "#FBBF24", label: "Needs Input", pulse: true },
  idle: { color: "#6B7280", label: "Idle", pulse: false },
  error: { color: "#F87171", label: "Error", pulse: true },
};

const TYPE_ICONS = { file: "◎", url: "◈", snippet: "❮❯", note: "✎" };

const CSS = `
@keyframes fadeIn {
  from { opacity: 0; transform: translateY(-6px) scale(0.98); }
  to   { opacity: 1; transform: translateY(0) scale(1); }
}
@keyframes pulseRing {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.4; }
}
@keyframes subtlePulse {
  0%, 100% { opacity: 0.9; }
  50% { opacity: 0.5; }
}
@keyframes slideUp {
  from { opacity: 0; transform: translateY(8px); }
  to   { opacity: 1; transform: translateY(0); }
}
@keyframes shimmer {
  0% { background-position: -200% 0; }
  100% { background-position: 200% 0; }
}
* { box-sizing: border-box; margin: 0; padding: 0; }
::-webkit-scrollbar { width: 5px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.08); border-radius: 3px; }
::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.15); }
`;

function MenuBarIcon({ agents, onClick, isOpen }) {
  const dots = [];
  const w = agents.filter(a => a.status === "working").length;
  const wa = agents.filter(a => a.status === "waiting").length;
  const e = agents.filter(a => a.status === "error").length;
  if (w > 0) dots.push(STATUS_CONFIG.working.color);
  if (wa > 0) dots.push(STATUS_CONFIG.waiting.color);
  if (e > 0) dots.push(STATUS_CONFIG.error.color);

  const [hover, setHover] = useState(false);

  return (
    <button
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        background: isOpen ? "rgba(255,255,255,0.18)" : hover ? "rgba(255,255,255,0.1)" : "transparent",
        border: "none",
        borderRadius: 4,
        padding: "2px 8px",
        cursor: "pointer",
        display: "flex",
        alignItems: "center",
        gap: 5,
        height: 22,
        transition: "background 0.15s",
      }}
    >
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
        <rect x="1" y="2" width="14" height="12" rx="2.5" stroke="white" strokeWidth="1.2" fill="none" />
        <path d="M4.5 6L7 8L4.5 10" stroke="white" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
        <line x1="8.5" y1="10" x2="11.5" y2="10" stroke="white" strokeWidth="1.2" strokeLinecap="round" />
      </svg>
      <div style={{ display: "flex", gap: 3, alignItems: "center" }}>
        {dots.map((c, i) => (
          <div key={i} style={{ position: "relative", width: 8, height: 8 }}>
            <div style={{ width: 8, height: 8, borderRadius: "50%", backgroundColor: c, position: "relative", zIndex: 1 }} />
            <div style={{
              position: "absolute", top: -2, left: -2, width: 12, height: 12, borderRadius: "50%",
              border: `1.5px solid ${c}`, animation: "pulseRing 2s ease-in-out infinite", opacity: 0.5,
            }} />
          </div>
        ))}
        <span style={{
          color: "rgba(255,255,255,0.8)", fontSize: 10,
          fontFamily: "'SF Mono', 'Fira Code', monospace", fontWeight: 500, marginLeft: 1,
        }}>
          {agents.length}
        </span>
      </div>
    </button>
  );
}

function ContextBar({ usage }) {
  const color = usage > 0.8 ? "#F87171" : usage > 0.6 ? "#FBBF24" : "rgba(255,255,255,0.3)";
  return (
    <div style={{ width: "100%", height: 3, borderRadius: 2, backgroundColor: "rgba(255,255,255,0.06)", overflow: "hidden" }}>
      <div style={{
        width: `${usage * 100}%`, height: "100%", borderRadius: 2, backgroundColor: color,
        transition: "width 0.8s cubic-bezier(0.16, 1, 0.3, 1)",
      }} />
    </div>
  );
}

function ActionBtn({ color, label, primary }) {
  const [h, setH] = useState(false);
  return (
    <div
      onMouseEnter={() => setH(true)}
      onMouseLeave={() => setH(false)}
      style={{
        padding: "4px 10px", borderRadius: 5, cursor: "pointer", userSelect: "none",
        border: `1px solid ${h ? color : primary ? `${color}40` : "rgba(255,255,255,0.1)"}`,
        color: h || primary ? color : "rgba(255,255,255,0.45)",
        fontSize: 10, fontFamily: "-apple-system, sans-serif", fontWeight: 500,
        background: h ? `${color}15` : primary ? `${color}0A` : "transparent",
        transition: "all 0.15s",
      }}
    >
      {label}
    </div>
  );
}

function AgentRow({ agent, index, isExpanded, onToggle }) {
  const cfg = STATUS_CONFIG[agent.status];
  const [hover, setHover] = useState(false);

  return (
    <div style={{ animation: `slideUp 0.3s cubic-bezier(0.16, 1, 0.3, 1) ${index * 0.04}s both` }}>
      <div
        onClick={onToggle}
        onMouseEnter={() => setHover(true)}
        onMouseLeave={() => setHover(false)}
        style={{
          padding: "10px 14px", cursor: "pointer", display: "flex", alignItems: "flex-start",
          gap: 10, borderRadius: 8, transition: "background 0.15s",
          background: isExpanded ? "rgba(255,255,255,0.06)" : hover ? "rgba(255,255,255,0.03)" : "transparent",
        }}
      >
        <div style={{ paddingTop: 4, flexShrink: 0, position: "relative" }}>
          <div style={{ width: 10, height: 10, borderRadius: "50%", backgroundColor: cfg.color, position: "relative", zIndex: 1 }} />
          {cfg.pulse && (
            <div style={{
              position: "absolute", top: 1, left: -3, width: 16, height: 16, borderRadius: "50%",
              backgroundColor: cfg.color, opacity: 0.15, animation: "subtlePulse 2s ease-in-out infinite",
            }} />
          )}
        </div>

        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <span style={{
              color: "#F0F0F0", fontSize: 13, fontWeight: 600,
              fontFamily: "'SF Mono', 'Fira Code', 'JetBrains Mono', monospace", letterSpacing: "-0.02em",
            }}>
              {agent.name}
            </span>
            <span style={{ color: "rgba(255,255,255,0.3)", fontSize: 10, fontFamily: "'SF Mono', monospace", flexShrink: 0 }}>
              {agent.elapsed}
            </span>
          </div>
          <div style={{
            color: agent.status === "error" ? "#F8717199" : agent.status === "waiting" ? "#FBBF2499" : "rgba(255,255,255,0.4)",
            fontSize: 11, marginTop: 2, fontFamily: "-apple-system, sans-serif",
            whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
          }}>
            {agent.lastAction}
          </div>
          <div style={{ marginTop: 6, display: "flex", alignItems: "center", gap: 8 }}>
            <div style={{ flex: 1 }}><ContextBar usage={agent.contextUsage} /></div>
            <span style={{
              fontSize: 9, color: agent.contextUsage > 0.8 ? "#F87171" : "rgba(255,255,255,0.2)",
              fontFamily: "'SF Mono', monospace", flexShrink: 0,
            }}>
              {Math.round(agent.contextUsage * 100)}%
            </span>
          </div>

          {isExpanded && (
            <div style={{
              marginTop: 10, paddingTop: 10,
              borderTop: "1px solid rgba(255,255,255,0.06)",
              animation: "fadeIn 0.2s ease both",
            }}>
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "6px 16px" }}>
                {[
                  ["Task", agent.task],
                  ["Branch", agent.branch],
                  ["Model", agent.model],
                  ["Project", agent.project],
                  ["Cost", `$${agent.cost.toFixed(2)}`],
                  ["Status", cfg.label],
                ].map(([label, value]) => (
                  <div key={label}>
                    <span style={{
                      color: "rgba(255,255,255,0.25)", fontSize: 9,
                      fontFamily: "-apple-system, sans-serif", textTransform: "uppercase", letterSpacing: "0.06em",
                    }}>{label}</span>
                    <div style={{
                      color: label === "Cost" ? "#FBBF24" : label === "Status" ? cfg.color : "rgba(255,255,255,0.65)",
                      fontSize: 11, fontFamily: "'SF Mono', monospace", marginTop: 1,
                      whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
                    }}>{value}</div>
                  </div>
                ))}
              </div>
              <div style={{ display: "flex", gap: 6, marginTop: 10, flexWrap: "wrap" }}>
                {agent.status === "waiting" && <ActionBtn color="#FBBF24" label="⏎ Approve" primary />}
                {agent.status === "error" && <ActionBtn color="#F87171" label="↻ Retry" primary />}
                {agent.status === "error" && <ActionBtn color="#F87171" label="New Session" />}
                <ActionBtn color="rgba(255,255,255,0.5)" label="Open Terminal" />
                {agent.status !== "idle" && <ActionBtn color="rgba(255,255,255,0.35)" label="Stop" />}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function InboxItem({ item, index }) {
  const [hover, setHover] = useState(false);
  return (
    <div
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: "flex", alignItems: "center", gap: 10, padding: "8px 14px",
        borderRadius: 8, cursor: "pointer", transition: "background 0.15s",
        background: hover ? "rgba(255,255,255,0.04)" : "transparent",
        animation: `slideUp 0.3s cubic-bezier(0.16, 1, 0.3, 1) ${index * 0.04}s both`,
      }}
    >
      <span style={{ color: "rgba(255,255,255,0.25)", fontSize: 13, width: 22, textAlign: "center", flexShrink: 0, fontFamily: "monospace" }}>
        {TYPE_ICONS[item.type]}
      </span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{
          color: "rgba(255,255,255,0.7)", fontSize: 12, fontFamily: "-apple-system, sans-serif",
          whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
        }}>{item.name}</div>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 6, flexShrink: 0 }}>
        {item.project && (
          <span style={{
            color: "rgba(255,255,255,0.2)", fontSize: 9, fontFamily: "'SF Mono', monospace",
            padding: "2px 5px", borderRadius: 3, background: "rgba(255,255,255,0.04)",
          }}>{item.project}</span>
        )}
        <span style={{ color: "rgba(255,255,255,0.18)", fontSize: 10, fontFamily: "-apple-system, sans-serif" }}>
          {item.time}
        </span>
      </div>
    </div>
  );
}

export default function Clawdboard() {
  const [isOpen, setIsOpen] = useState(true);
  const [tab, setTab] = useState("agents");
  const [expandedAgent, setExpandedAgent] = useState(2);
  const [agents, setAgents] = useState(AGENTS);

  useEffect(() => {
    const iv = setInterval(() => {
      setAgents(prev => prev.map(a => ({
        ...a,
        contextUsage: Math.min(0.95, Math.max(0.05, a.contextUsage + (Math.random() - 0.48) * 0.02)),
        cost: Math.round((a.cost + (a.status === "working" ? 0.01 : 0)) * 100) / 100,
      })));
    }, 3000);
    return () => clearInterval(iv);
  }, []);

  const totalCost = agents.reduce((s, a) => s + a.cost, 0);
  const working = agents.filter(a => a.status === "working").length;
  const waiting = agents.filter(a => a.status === "waiting").length;
  const errors = agents.filter(a => a.status === "error").length;

  return (
    <div style={{
      width: "100vw", height: "100vh", overflow: "hidden", position: "relative",
      fontFamily: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif",
      background: `
        radial-gradient(ellipse at 25% 15%, #5B7F9E 0%, transparent 55%),
        radial-gradient(ellipse at 75% 85%, #3E6280 0%, transparent 55%),
        linear-gradient(145deg, #5A7B95, #4A6A84, #3D5E78)
      `,
    }}>
      <style>{CSS}</style>

      {/* Desktop noise texture */}
      <svg style={{ position: "absolute", inset: 0, width: "100%", height: "100%", opacity: 0.08, pointerEvents: "none", zIndex: 0 }}>
        <filter id="n"><feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="4" stitchTiles="stitch" /></filter>
        <rect width="100%" height="100%" filter="url(#n)" />
      </svg>

      {/* ─── macOS Menu Bar ─── */}
      <div style={{
        height: 25, display: "flex", alignItems: "center", justifyContent: "flex-end",
        paddingRight: 10, gap: 2, position: "relative", zIndex: 100,
        background: "rgba(36, 39, 48, 0.68)",
        backdropFilter: "blur(40px) saturate(1.8)",
        WebkitBackdropFilter: "blur(40px) saturate(1.8)",
        borderBottom: "0.5px solid rgba(255,255,255,0.06)",
      }}>
        {/* Decorative tray icons before ours */}
        {[
          <svg key="bt" width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M7 1v12M7 1l3 3-3 3m0 0l3 3-3 3" stroke="white" strokeWidth="1" strokeLinecap="round" strokeLinejoin="round" opacity="0.6" /></svg>,
          <svg key="vol" width="14" height="14" viewBox="0 0 14 14" fill="none"><rect x="2" y="5" width="3" height="4" rx="0.5" fill="white" opacity="0.6" /><path d="M5 5l3-2v8l-3-2" fill="white" opacity="0.6" /><path d="M9.5 4.5c1 1 1 4 0 5" stroke="white" strokeWidth="1" strokeLinecap="round" opacity="0.6" /></svg>,
        ].map((icon, i) => (
          <div key={i} style={{ padding: "0 5px", display: "flex", alignItems: "center" }}>{icon}</div>
        ))}

        <MenuBarIcon agents={agents} isOpen={isOpen} onClick={() => setIsOpen(!isOpen)} />

        {/* Battery */}
        <div style={{ padding: "0 5px", display: "flex", alignItems: "center" }}>
          <svg width="22" height="12" viewBox="0 0 22 12" fill="none">
            <rect x="0.5" y="1" width="18" height="10" rx="2" stroke="white" strokeWidth="0.8" opacity="0.6" />
            <rect x="19" y="4" width="2" height="4" rx="0.8" fill="white" opacity="0.4" />
            <rect x="2" y="2.5" width="12" height="7" rx="1" fill="white" opacity="0.5" />
          </svg>
        </div>
        <div style={{ padding: "0 5px", display: "flex", alignItems: "center" }}>
          <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
            <path d="M7 2c-3 0-5 2-6 5 1 3 3 5 6 5s5-2 6-5c-1-3-3-5-6-5z" stroke="white" strokeWidth="0.8" fill="none" opacity="0.6" />
            <circle cx="7" cy="7" r="1.5" fill="white" opacity="0.6" />
          </svg>
        </div>
        <span style={{
          color: "rgba(255,255,255,0.8)", fontSize: 12,
          fontFamily: "-apple-system, sans-serif", fontWeight: 400, paddingLeft: 6, paddingRight: 2,
        }}>
          Wed 11. 3.  17:34
        </span>
      </div>

      {/* ─── Dropdown Panel ─── */}
      {isOpen && (
        <div style={{
          position: "absolute", top: 29, right: 88, width: 380, maxHeight: "calc(100vh - 50px)",
          background: "rgba(28, 30, 38, 0.78)",
          backdropFilter: "blur(60px) saturate(2)",
          WebkitBackdropFilter: "blur(60px) saturate(2)",
          borderRadius: 12, overflow: "hidden", display: "flex", flexDirection: "column", zIndex: 99,
          border: "0.5px solid rgba(255,255,255,0.1)",
          boxShadow: "0 24px 80px rgba(0,0,0,0.5), 0 8px 24px rgba(0,0,0,0.3), inset 0 0.5px 0 rgba(255,255,255,0.06)",
          animation: "fadeIn 0.2s cubic-bezier(0.16, 1, 0.3, 1)",
        }}>
          {/* Header */}
          <div style={{ padding: "14px 16px 10px", borderBottom: "0.5px solid rgba(255,255,255,0.05)" }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{
                  fontSize: 14, fontWeight: 700, color: "#F0F0F0", letterSpacing: "-0.03em",
                  fontFamily: "'SF Pro Display', -apple-system, sans-serif",
                }}>Clawdboard</span>
                <span style={{
                  fontSize: 8, color: "rgba(255,255,255,0.2)", fontFamily: "'SF Mono', monospace",
                  background: "rgba(255,255,255,0.04)", padding: "2px 6px", borderRadius: 4,
                }}>PoC</span>
              </div>
              <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
                <span style={{ fontSize: 11, color: "#FBBF24", fontFamily: "'SF Mono', monospace", fontWeight: 600 }}>
                  ${totalCost.toFixed(2)}
                </span>
                <span style={{ fontSize: 9, color: "rgba(255,255,255,0.2)", fontFamily: "'SF Mono', monospace" }}>today</span>
              </div>
            </div>

            {/* Status pills */}
            <div style={{ display: "flex", gap: 6, marginTop: 8 }}>
              {[
                { label: `${working} working`, color: STATUS_CONFIG.working.color, show: working > 0 },
                { label: `${waiting} waiting`, color: STATUS_CONFIG.waiting.color, show: waiting > 0 },
                { label: `${errors} error`, color: STATUS_CONFIG.error.color, show: errors > 0 },
              ].filter(p => p.show).map((pill, i) => (
                <div key={i} style={{
                  display: "flex", alignItems: "center", gap: 4, padding: "3px 8px", borderRadius: 6,
                  background: `${pill.color}10`, border: `0.5px solid ${pill.color}20`,
                }}>
                  <div style={{ width: 6, height: 6, borderRadius: "50%", backgroundColor: pill.color }} />
                  <span style={{ fontSize: 10, color: pill.color, fontFamily: "-apple-system, sans-serif", fontWeight: 500 }}>
                    {pill.label}
                  </span>
                </div>
              ))}
            </div>

            {/* Tabs */}
            <div style={{
              display: "flex", gap: 0, marginTop: 10,
              background: "rgba(255,255,255,0.03)", borderRadius: 7, padding: 2,
            }}>
              {[
                { key: "agents", label: "Sessions", count: agents.length },
                { key: "inbox", label: "Context Inbox", count: INBOX_ITEMS.length },
              ].map(t => (
                <button key={t.key} onClick={() => setTab(t.key)} style={{
                  flex: 1, padding: "5px 0", border: "none", borderRadius: 5, cursor: "pointer",
                  background: tab === t.key ? "rgba(255,255,255,0.09)" : "transparent",
                  color: tab === t.key ? "#F0F0F0" : "rgba(255,255,255,0.3)",
                  fontSize: 11, fontFamily: "-apple-system, sans-serif", fontWeight: 500,
                  transition: "all 0.15s", display: "flex", alignItems: "center", justifyContent: "center", gap: 5,
                }}>
                  {t.label}
                  <span style={{ fontSize: 9, fontFamily: "'SF Mono', monospace", opacity: 0.5 }}>{t.count}</span>
                </button>
              ))}
            </div>
          </div>

          {/* Content */}
          <div style={{ flex: 1, overflowY: "auto", padding: "4px 4px", maxHeight: 440 }}>
            {tab === "agents" && (
              <>
                {/* Active section header */}
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "8px 14px 4px" }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                    <span style={{
                      color: "rgba(255,255,255,0.3)", fontSize: 10, fontFamily: "-apple-system, sans-serif",
                      fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.08em",
                    }}>Active</span>
                    <span style={{
                      color: "rgba(255,255,255,0.15)", fontSize: 10, fontFamily: "'SF Mono', monospace",
                      backgroundColor: "rgba(255,255,255,0.04)", padding: "1px 5px", borderRadius: 4,
                    }}>{agents.filter(a => a.status !== "idle").length}</span>
                  </div>
                </div>
                {agents
                  .filter(a => a.status !== "idle")
                  .sort((a, b) => {
                    const o = { error: 0, waiting: 1, working: 2 };
                    return o[a.status] - o[b.status];
                  })
                  .map((agent, i) => (
                    <AgentRow key={agent.id} agent={agent} index={i}
                      isExpanded={expandedAgent === agent.id}
                      onToggle={() => setExpandedAgent(expandedAgent === agent.id ? null : agent.id)}
                    />
                  ))}
                <div style={{ height: 4 }} />
                <div style={{ padding: "8px 14px 4px" }}>
                  <span style={{
                    color: "rgba(255,255,255,0.3)", fontSize: 10, fontFamily: "-apple-system, sans-serif",
                    fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.08em",
                  }}>Idle</span>
                </div>
                {agents.filter(a => a.status === "idle").map((agent, i) => (
                  <AgentRow key={agent.id} agent={agent} index={i + 5}
                    isExpanded={expandedAgent === agent.id}
                    onToggle={() => setExpandedAgent(expandedAgent === agent.id ? null : agent.id)}
                  />
                ))}
              </>
            )}

            {tab === "inbox" && (
              <>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "8px 14px 4px" }}>
                  <span style={{
                    color: "rgba(255,255,255,0.3)", fontSize: 10, fontFamily: "-apple-system, sans-serif",
                    fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.08em",
                  }}>Queued Context</span>
                  <span style={{
                    fontSize: 10, color: "rgba(255,255,255,0.25)", cursor: "pointer",
                    fontFamily: "-apple-system, sans-serif",
                  }}>+ Add</span>
                </div>
                {INBOX_ITEMS.map((item, i) => <InboxItem key={item.id} item={item} index={i} />)}

                {/* Drop zone */}
                <div style={{
                  margin: "12px 14px", padding: "20px 16px",
                  border: "1.5px dashed rgba(255,255,255,0.08)", borderRadius: 10,
                  textAlign: "center", cursor: "pointer", transition: "all 0.2s",
                }}
                  onMouseEnter={e => { e.currentTarget.style.borderColor = "rgba(255,255,255,0.2)"; }}
                  onMouseLeave={e => { e.currentTarget.style.borderColor = "rgba(255,255,255,0.08)"; }}
                >
                  <div style={{ color: "rgba(255,255,255,0.2)", fontSize: 11, fontFamily: "-apple-system, sans-serif" }}>
                    <span style={{ fontSize: 18, display: "block", marginBottom: 4, opacity: 0.5 }}>+</span>
                    Drop files, URLs, or snippets
                    <div style={{ fontSize: 10, marginTop: 4, opacity: 0.5 }}>
                      Drag to a session when ready
                    </div>
                  </div>
                </div>
              </>
            )}
          </div>

          {/* Footer */}
          <div style={{
            padding: "8px 14px", borderTop: "0.5px solid rgba(255,255,255,0.05)",
            display: "flex", justifyContent: "space-between", alignItems: "center",
          }}>
            <div style={{ display: "flex", gap: 14 }}>
              {["+ New Session", "Settings"].map(label => (
                <span key={label} style={{
                  fontSize: 10, color: "rgba(255,255,255,0.2)", cursor: "pointer",
                  fontFamily: "-apple-system, sans-serif", transition: "color 0.15s",
                }}
                  onMouseEnter={e => e.currentTarget.style.color = "rgba(255,255,255,0.5)"}
                  onMouseLeave={e => e.currentTarget.style.color = "rgba(255,255,255,0.2)"}
                >{label}</span>
              ))}
            </div>
            <span style={{ fontSize: 9, color: "rgba(255,255,255,0.12)", fontFamily: "'SF Mono', monospace" }}>⌘⇧A</span>
          </div>
        </div>
      )}
    </div>
  );
}

```

## How to build and run

After generating all files:
```bash
cd Clawdboard
swift build
swift run
# Or open in Xcode:
open Package.swift
```

## Important notes
- This is a menu bar-only app — no Dock icon. Add `LSUIElement = true` to Info.plist or use the Application.isAgent approach
- The panel should be the right width for a menu bar dropdown (~380pt), not a full window
- Keep the PoC focused on the UI with mock data — real session discovery comes later
- Make sure it compiles and runs — don't leave syntax errors

# VERY IMPORTANT NOTES
- THIS IS AN AUTOGENERATED TASK, MAKE SURE TO DISCUSS ALL CHANGES AND MAKE DIFFERENT ARCHITECTURAL DECISIONS OR DIFFERENT FILE STRUCTURE ETC.
- DO WHAT MAKES SENSE NOT EXACTLY WHAT IS DESCRIBED HERE
- Ask me any questions, experiment and check things in the terminal, for example we may use claude HOOKS to determine what sessions are running instead of watching files
- This is a clean repository, add lints and checks and tests as much as possible - test everything that you can
