import AppKit
import ClawdboardLib
import ServiceManagement
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Register as login item only when running as a bundled .app
        // (skip in development when launched via `swift run` from terminal)
        if Bundle.main.bundlePath.hasSuffix(".app"),
            SMAppService.mainApp.status != .enabled
        {
            try? SMAppService.mainApp.register()
        }

        installCLISymlink()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.checkAndInstallHooks()
        }
    }

    /// Installs a wrapper script at /usr/local/bin/clawdboard that opens the .app bundle.
    /// A direct symlink to the binary won't work because Bundle.main wouldn't resolve
    /// to the .app, breaking SPM resource bundle lookup.
    private func installCLISymlink() {
        let scriptPath = "/usr/local/bin/clawdboard"
        let appPath = Bundle.main.bundleURL.path
        let script = "#!/bin/sh\nopen \"\(appPath)\"\n"

        // Already correct
        if let existing = try? String(contentsOfFile: scriptPath, encoding: .utf8),
            existing == script
        {
            return
        }

        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        chmod(scriptPath, 0o755)
    }

    static func checkAndInstallHooks() {
        let hookManager = HookManager.shared

        // Always update hook script (idempotent)
        try? hookManager.installHookScript()

        // If all expected hooks are registered, nothing more to do
        guard !hookManager.isInstalled else { return }

        let alert = NSAlert()
        alert.messageText = "Install Session Tracking Hooks?"
        alert.informativeText = """
            Clawdboard needs to add hooks to your Claude Code settings \
            (~/.claude/settings.json) to track session status in real-time.

            This enables:
            • Detecting when sessions start and end
            • Knowing when a session is waiting for your input
            • Tracking context usage and cost per session

            Your existing Claude settings will be preserved. \
            You can remove hooks anytime from Clawdboard settings.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Hooks")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try hookManager.installHooksInSettings()
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Hook Installation Failed"
                errorAlert.informativeText = error.localizedDescription
                errorAlert.alertStyle = .warning
                errorAlert.runModal()
            }
        }
    }
}

@main
struct ClawdboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState: AppState = {
        let state = AppState()
        state.start()
        return state
    }()
    var body: some Scene {
        Window("Clawdboard", id: "main") {
            ZStack {
                Color.clear
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                    .background(.thinMaterial)
                    .ignoresSafeArea()

                DetachedPanelView()
                    .environment(appState)
            }
            .background(WindowConfigurator())
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 420, height: 520)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            PanelView()
                .environment(appState)
        } label: {
            MenuBarLabelWithLauncher(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .background(SettingsWindowConfigurator())
        }
    }
}

/// Sets the hosting window to float above normal windows so it stays always visible.
/// Resets the "showFloatingWindow" preference when the window is closed via the X button.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.titlebarAppearsTransparent = true
                window.isOpaque = false
                window.backgroundColor = .clear
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true

                context.coordinator.observe(window)
                Self.setupInitialState(window: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Animate close button, toolbar menu button, and title on hover.
    static func setHoverState(window: NSWindow, hovering: Bool) {
        let alpha: CGFloat = hovering ? 1 : 0

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2

            // Close button — snap visibility (system widget doesn't animate alpha cleanly)
            window.standardWindowButton(.closeButton)?.isHidden = !hovering

            // Title — use alphaValue so it animates on the same curve as the menu button
            findView(in: window, matching: "ToolbarTitleView")?.animator().alphaValue =
                hovering ? 1.0 : 0.3

            // Toolbar item viewer (menu button)
            findView(in: window, matching: "ToolbarItemViewer")?.animator().alphaValue = alpha
        }
    }

    /// Initial setup: dim title, hide buttons, permanently hide the glass pill.
    static func setupInitialState(window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = true

        findView(in: window, matching: "ToolbarTitleView")?.alphaValue = 0.3

        func setup(_ view: NSView) {
            let name = String(describing: type(of: view))
            if name.contains("ToolbarPlatterView") {
                view.isHidden = true
                return
            }
            if name.contains("ToolbarItemViewer") {
                view.alphaValue = 0
                return
            }
            for sub in view.subviews { setup(sub) }
        }

        if let container = window.standardWindowButton(.closeButton)?.superview?.superview {
            setup(container)
        }

        // Pin the title view to full width so toolbar layout changes don't shift it
        if let titleView = findView(in: window, matching: "ToolbarTitleView") {
            titleView.translatesAutoresizingMaskIntoConstraints = false
            if let superview = titleView.superview {
                NSLayoutConstraint.activate([
                    titleView.centerXAnchor.constraint(equalTo: superview.centerXAnchor),
                    titleView.centerYAnchor.constraint(equalTo: superview.centerYAnchor),
                ])
            }
        }
    }

    /// Recursively find a view whose class name contains the given string.
    private static func findView(in window: NSWindow, matching className: String) -> NSView? {
        guard let root = window.standardWindowButton(.closeButton)?.superview?.superview
        else { return nil }
        func search(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains(className) { return view }
            for sub in view.subviews {
                if let found = search(sub) { return found }
            }
            return nil
        }
        return search(root)
    }

    final class Coordinator: NSObject {
        private var observation: Any?

        func observe(_ window: NSWindow) {
            observation = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window, queue: .main
            ) { _ in
                UserDefaults.standard.set(false, forKey: "showFloatingWindow")
            }

            // Add a tracking view to detect mouse enter/exit on the window
            guard let contentView = window.contentView else { return }
            let tracker = ToolbarHoverTracker(window: window)
            tracker.frame = contentView.bounds
            tracker.autoresizingMask = [.width, .height]
            contentView.addSubview(tracker)
        }

        deinit { observation.map(NotificationCenter.default.removeObserver) }
    }
}

/// Invisible tracking view that shows/hides toolbar items on window hover.
private final class ToolbarHoverTracker: NSView {
    weak var trackedWindow: NSWindow?

    init(window: NSWindow) {
        self.trackedWindow = window
        super.init(frame: .zero)
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Pass all clicks through to the views below
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        guard let window = trackedWindow else { return }
        WindowConfigurator.setHoverState(window: window, hovering: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard let window = trackedWindow else { return }
        WindowConfigurator.setHoverState(window: window, hovering: false)
    }
}

/// Ensures the Settings window floats above other windows.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.level = .floating
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Thin wrapper around MenuBarLabel that optionally opens the floating window at launch.
struct MenuBarLabelWithLauncher: View {
    let appState: AppState
    @AppStorage("showFloatingWindow") private var showFloatingWindow = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarLabel(appState: appState)
            .task {
                if showFloatingWindow {
                    openWindow(id: "main")
                }
            }
    }
}

/// Menu bar label rendered as an NSImage so we get proper SF Symbols + text.
/// SwiftUI MenuBarExtra labels don't reliably render complex view hierarchies,
/// but a single Image backed by a rendered NSImage works perfectly.
struct MenuBarLabel: View {
    let appState: AppState
    @AppStorage("useRedYellowMode") private var useRedYellowMode = true
    @AppStorage("usageRingThreshold") private var usageRingThreshold = 50
    @State private var menuBarAppearanceObserver = MenuBarAppearanceObserver()

    /// Usage fill percentage (0–100) from the 5-hour usage limit, nil if unavailable.
    private var usagePct: CGFloat? {
        guard let limits = appState.usageLimits else { return nil }
        return CGFloat(limits.fiveHour.utilization)
    }

    /// Whether the usage ring should be shown (above threshold).
    private var showRing: Bool {
        guard let pct = usagePct else { return false }
        return pct >= CGFloat(usageRingThreshold)
    }

    var body: some View {
        let approval = appState.needsApprovalCount
        let waiting = appState.waitingCount
        let working = appState.workingCount
        // Read to establish SwiftUI dependency so we redraw on appearance changes
        let _ = menuBarAppearanceObserver.isDark

        if approval == 0 && waiting == 0 {
            // No urgent states (approval/waiting) - just show the terminal icon
            // Blue "working" dots were hard to see against some backgrounds
            if showRing, let pct = usagePct,
                let img = Self.renderRingOnly(pct: pct)
            {
                Image(nsImage: img)
            } else {
                Image(systemName: "apple.terminal")
            }
        } else if let image = Self.renderDotsImage(
            approval: approval, waiting: waiting, working: working,
            useRedYellowMode: useRedYellowMode,
            usagePct: showRing ? usagePct : nil
        ) {
            Image(nsImage: image)
        }
    }

    // MARK: - Ring Drawing

    /// Draw a circular progress ring into the current graphics context.
    /// Uses the provided foreground color for the arc and a faded version for the track.
    private static func drawRing(
        center: NSPoint, radius: CGFloat, lineWidth: CGFloat, pct: CGFloat,
        color: NSColor = .black
    ) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        color.withAlphaComponent(0.2).setStroke()
        track.lineWidth = lineWidth
        track.stroke()

        if pct > 0 {
            let endAngle: CGFloat = 90 - (min(pct, 100) / 100) * 360
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: radius,
                startAngle: 90, endAngle: endAngle, clockwise: true
            )
            color.setStroke()
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            arc.stroke()
        }
    }

    /// Create a bitmap rep for menu bar rendering at Retina scale.
    private static func makeMenuBarRep(size: NSSize) -> (NSBitmapImageRep, NSSize) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelSize = NSSize(width: size.width * scale, height: size.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        return (rep, size)
    }

    /// Render a standalone usage ring for idle state. Always template.
    private static func renderRingOnly(pct: CGFloat) -> NSImage? {
        let menuBarHeight = NSStatusBar.system.thickness
        let ringDiameter: CGFloat = 14
        let imageSize = NSSize(width: ringDiameter, height: menuBarHeight)

        let (rep, _) = makeMenuBarRep(size: imageSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        drawRing(
            center: NSPoint(x: ringDiameter / 2, y: menuBarHeight / 2),
            radius: ringDiameter / 2 - 2, lineWidth: 2.5, pct: pct
        )

        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: imageSize)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    /// Render one colored dot per active session, ordered by urgency.
    /// Caps at maxDots to keep menu bar compact.
    /// The usage ring is drawn using the resolved menu bar foreground color
    /// so it adapts to wallpaper-driven tinting while dots keep their colors.
    private static func renderDotsImage(
        approval: Int, waiting: Int, working: Int,
        useRedYellowMode: Bool,
        usagePct: CGFloat? = nil
    ) -> NSImage? {
        // Build dot list: most urgent first
        // Only show red (approval) and green (waiting) - these are actionable states
        // Blue "working" dots were hard to see and don't need user attention
        var dots: [NSColor] = []
        for _ in 0..<approval { dots.append(.systemRed) }
        for _ in 0..<waiting { dots.append(.systemGreen) }
        guard !dots.isEmpty else { return nil }

        let maxDots = 8
        let capped = dots.prefix(maxDots)

        let dotSize: CGFloat = 8
        let dotSpacing: CGFloat = 4
        let menuBarHeight = NSStatusBar.system.thickness

        let ringDiameter: CGFloat = 14
        let ringSpacing: CGFloat = 6
        let hasRing = usagePct != nil
        let ringExtra: CGFloat = hasRing ? (ringSpacing + ringDiameter) : 0

        let dotsWidth = CGFloat(capped.count) * dotSize + CGFloat(capped.count - 1) * dotSpacing
        let imageSize = NSSize(
            width: dotsWidth + ringExtra,
            height: menuBarHeight
        )
        let (rep, _) = makeMenuBarRep(size: imageSize)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        // Draw dots
        let dotY = (menuBarHeight - dotSize) / 2
        for (index, color) in capped.enumerated() {
            let x = CGFloat(index) * (dotSize + dotSpacing)
            let dotRect = NSRect(x: x, y: dotY, width: dotSize, height: dotSize)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        // Draw the usage ring using the menu bar's resolved foreground color,
        // derived from the NSStatusBarWindow's effectiveAppearance which
        // accounts for wallpaper-driven tinting — not just system dark mode.
        if let pct = usagePct {
            let ringColor = statusBarForegroundColor()
            let ringX = dotsWidth + ringSpacing + ringDiameter / 2
            drawRing(
                center: NSPoint(x: ringX, y: menuBarHeight / 2),
                radius: ringDiameter / 2 - 2, lineWidth: 2.5, pct: pct,
                color: ringColor
            )
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: imageSize)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    /// Resolve the correct foreground color for menu bar items.
    /// Finds the NSStatusBarWindow (created by macOS for each status item) and reads
    /// its effectiveAppearance, which is set based on the wallpaper behind the menu bar
    /// — not just system-wide dark/light mode.
    private static func statusBarForegroundColor() -> NSColor {
        for window in NSApp.windows
        where String(describing: type(of: window)).contains("StatusBar") {
            let appearance = window.effectiveAppearance
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? .white : .black
        }
        // Fallback: use app-level appearance
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .white : .black
    }
}

/// Observes the NSStatusBarWindow's effectiveAppearance via KVO so SwiftUI
/// redraws the menu bar label when the wallpaper-driven tinting changes.
@Observable
final class MenuBarAppearanceObserver: NSObject {
    var isDark: Bool = false
    private var kvoToken: NSKeyValueObservation?
    private weak var observedWindow: NSWindow?

    override init() {
        super.init()
        // Defer so the status bar window exists
        DispatchQueue.main.async { [weak self] in
            self?.attachObserver()
        }
    }

    private func attachObserver() {
        guard
            let window = NSApp.windows.first(where: {
                String(describing: type(of: $0)).contains("StatusBar")
            })
        else {
            debugLog("[MenuBarAppearance] No StatusBarWindow found, will retry")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.attachObserver()
            }
            return
        }

        observedWindow = window
        let currentlyDark =
            window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        isDark = currentlyDark
        debugLog("[MenuBarAppearance] Attached to StatusBarWindow, isDark=\(isDark)")

        kvoToken = window.observe(\.effectiveAppearance, options: [.new]) {
            [weak self] window, _ in
            let newDark =
                window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            debugLog("[MenuBarAppearance] Appearance changed, isDark=\(newDark)")
            DispatchQueue.main.async {
                self?.isDark = newDark
            }
        }
    }

    deinit {
        kvoToken?.invalidate()
    }
}
