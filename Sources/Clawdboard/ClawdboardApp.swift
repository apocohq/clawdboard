import AppKit
import ClawdboardLib
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.checkAndInstallHooks()
        }
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
                    .background(.ultraThinMaterial)
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
                .onAppear {
                    for window in NSApplication.shared.windows
                    where window.identifier?.rawValue.contains("settings") == true
                        || window.title.contains("Settings")
                    {
                        window.level = .floating
                    }
                }
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

        if approval == 0 && waiting == 0 && working == 0 {
            if showRing, let pct = usagePct,
                let img = Self.renderRingOnly(pct: pct)
            {
                Image(nsImage: img)
            } else {
                Image(systemName: "terminal")
            }
        } else if let image = Self.renderStatusImage(
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

    /// Render SF Symbols + counts into an NSImage suitable for the menu bar.
    /// Pill background color depends on state and user's color mode preference.
    private static func renderStatusImage(
        approval: Int, waiting: Int, working: Int,
        useRedYellowMode: Bool,
        usagePct: CGFloat? = nil
    ) -> NSImage? {
        var segments: [(symbol: String, count: Int)] = []
        if approval > 0 {
            segments.append(("exclamationmark.triangle.fill", approval))
        }
        if waiting > 0 {
            segments.append(("hourglass", waiting))
        }
        if working > 0 {
            segments.append(("bolt.fill", working))
        }
        guard !segments.isEmpty else { return nil }

        // Determine pill background color based on mode:
        // Red+Yellow mode: red for approval, yellow for waiting-only
        // Yellow-only mode: yellow for approval, no pill for waiting-only
        let pillColor: NSColor?
        let needsDarkText: Bool
        if approval > 0 && useRedYellowMode {
            pillColor = .systemRed
            needsDarkText = false
        } else if approval > 0 {
            pillColor = .systemYellow
            needsDarkText = true
        } else if waiting > 0 && useRedYellowMode {
            pillColor = .systemYellow
            needsDarkText = true
        } else {
            pillColor = nil
            needsDarkText = false
        }

        let hasPill = pillColor != nil
        let foreground: NSColor
        let dotForeground: NSColor
        if hasPill {
            foreground = needsDarkText ? .black : .white
            dotForeground =
                needsDarkText
                ? .black.withAlphaComponent(0.5) : .white.withAlphaComponent(0.7)
        } else {
            // Template mode: draw in black, macOS adapts to menu bar
            foreground = .black
            dotForeground = .gray
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
        ]
        let dotAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: dotForeground,
        ]

        let result = NSMutableAttributedString()

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: " · ", attributes: dotAttrs))
            }

            if var symbolImage = NSImage(
                systemSymbolName: segment.symbol, accessibilityDescription: nil
            ) {
                symbolImage = symbolImage.withSymbolConfiguration(symbolConfig) ?? symbolImage
                if hasPill {
                    let tinted = NSImage(size: symbolImage.size)
                    tinted.lockFocus()
                    symbolImage.draw(in: NSRect(origin: .zero, size: symbolImage.size))
                    foreground.set()
                    NSRect(origin: .zero, size: symbolImage.size).fill(using: .sourceIn)
                    tinted.unlockFocus()
                    symbolImage = tinted
                }
                let attachment = NSTextAttachment()
                attachment.image = symbolImage
                let mid = font.capHeight / 2
                attachment.bounds = CGRect(
                    x: 0, y: mid - symbolImage.size.height / 2,
                    width: symbolImage.size.width, height: symbolImage.size.height
                )
                result.append(NSAttributedString(attachment: attachment))
            }

            result.append(NSAttributedString(string: "\(segment.count)", attributes: textAttrs))
        }

        let textSize = result.size()
        let hPad: CGFloat = hasPill ? 4.0 : 0
        let menuBarHeight = NSStatusBar.system.thickness

        let ringDiameter: CGFloat = 14
        let ringSpacing: CGFloat = 4
        let hasRing = usagePct != nil
        let ringPadRight: CGFloat = (hasRing && hasPill) ? hPad : 0
        let ringExtra: CGFloat = hasRing ? (ringSpacing + ringDiameter + ringPadRight) : 0

        let imageSize = NSSize(
            width: ceil(textSize.width) + hPad * 2 + ringExtra,
            height: menuBarHeight
        )
        let (rep, _) = makeMenuBarRep(size: imageSize)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        if let color = pillColor {
            // Pill covers everything including the ring
            let pillRect = NSRect(origin: .zero, size: imageSize)
            let path = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
            color.setFill()
            path.fill()
        }

        let textY = (imageSize.height - textSize.height) / 2
        result.draw(at: NSPoint(x: hPad, y: textY))

        // Ring after the pill
        if let pct = usagePct {
            let pillWidth = ceil(textSize.width) + hPad * 2
            drawRing(
                center: NSPoint(
                    x: pillWidth + ringSpacing + ringDiameter / 2,
                    y: menuBarHeight / 2
                ),
                radius: ringDiameter / 2 - 2, lineWidth: 2.5, pct: pct,
                color: foreground
            )
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: imageSize)
        image.addRepresentation(rep)
        // Template when no pill — ring is black so it adapts too
        image.isTemplate = !hasPill
        return image
    }
}
