import AppKit
import ClawdboardLib
import Observation
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private(set) var appState: AppState!
    private var defaultsObservers: [Any] = []
    private var floatingWindow: NSWindow?

    /// Shared reference so the App struct can access appState for Settings.
    static var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)

        // Register defaults so UserDefaults reads match @AppStorage defaults.
        UserDefaults.standard.register(defaults: [
            "useRedYellowMode": true,
            "usageRingThreshold": 50,
        ])

        appState = AppState()
        appState.start()

        setupStatusItem()
        setupPopover()
        updateStatusItem()

        // Observe appState changes to update the menu bar icon.
        // AppState is @Observable, so we use withObservationTracking in a loop.
        startObserving()
        observeDefaults()
        observeFloatingWindowNotifications()

        // Open the floating window at launch if the preference is set.
        if UserDefaults.standard.bool(forKey: "showFloatingWindow") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.openFloatingWindow()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.checkAndInstallHooks()
        }
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            button.target = self
            button.action = #selector(togglePopover)
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 500)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PanelView().environment(appState)
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Ensure the popover's window is key so it can receive events
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Status Item Updates

    private func observeDefaults() {
        let obs = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateStatusItem()
        }
        defaultsObservers.append(obs)
    }

    private func startObserving() {
        // Use withObservationTracking to re-render whenever AppState changes.
        withObservationTracking {
            // Access the properties we care about to register tracking
            _ = appState.needsApprovalCount
            _ = appState.waitingCount
            _ = appState.workingCount
            _ = appState.usageLimits
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusItem()
                self?.startObserving()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let approval = appState.needsApprovalCount
        let waiting = appState.waitingCount
        let working = appState.workingCount

        let useRedYellowMode = UserDefaults.standard.bool(forKey: "useRedYellowMode")
        let usageRingThreshold = UserDefaults.standard.integer(forKey: "usageRingThreshold")
        let effectiveThreshold = usageRingThreshold > 0 ? usageRingThreshold : 50

        let usagePct: CGFloat? = {
            guard let limits = appState.usageLimits else { return nil }
            return CGFloat(limits.fiveHour.utilization)
        }()
        let showRing = usagePct.map { $0 >= CGFloat(effectiveThreshold) } ?? false

        if approval == 0 && waiting == 0 && working == 0 {
            // Idle state
            if showRing, let pct = usagePct,
                let img = MenuBarRenderer.renderRingOnly(pct: pct)
            {
                button.image = img
            } else {
                button.image = NSImage(
                    systemSymbolName: "terminal", accessibilityDescription: nil
                )
            }
            // Clear any pill background
            button.wantsLayer = true
            button.layer?.backgroundColor = nil
        } else if let (image, pillColor) = MenuBarRenderer.renderStatusImage(
            approval: approval, waiting: waiting, working: working,
            useRedYellowMode: useRedYellowMode,
            usagePct: showRing ? usagePct : nil
        ) {
            button.image = image
            // Apply pill background directly on the button's layer
            // so it fills the system's exact button bounds (no pill-inside-pill).
            button.wantsLayer = true
            if let color = pillColor {
                button.layer?.backgroundColor = color.cgColor
                button.layer?.cornerRadius = button.frame.height / 2
                button.layer?.masksToBounds = true
            } else {
                button.layer?.backgroundColor = nil
            }
        }
    }

    // MARK: - Floating Window

    private func observeFloatingWindowNotifications() {
        NotificationCenter.default.addObserver(
            forName: .openFloatingWindow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.openFloatingWindow()
            // Dismiss the popover when detaching
            self?.popover.performClose(nil)
        }
        NotificationCenter.default.addObserver(
            forName: .closeFloatingWindow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.closeFloatingWindow()
        }
    }

    func openFloatingWindow() {
        // If already open, just bring it front
        if let existing = floatingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(
            rootView: ZStack {
                Color.clear
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                    .background(.thinMaterial)
                    .ignoresSafeArea()

                DetachedPanelView()
                    .environment(appState!)
            }
        )

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        window.title = "Clawdboard"
        window.contentView = hostingView
        window.center()
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.closeButton)?.isHidden = true

        // Add hover tracking for close button visibility
        let tracker = FloatingWindowHoverTracker(window: window)
        tracker.frame = hostingView.bounds
        tracker.autoresizingMask = [.width, .height]
        hostingView.addSubview(tracker)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        floatingWindow = window

        // Reset pref when closed via the X button
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            UserDefaults.standard.set(false, forKey: "showFloatingWindow")
            self?.floatingWindow = nil
        }
    }

    private func closeFloatingWindow() {
        floatingWindow?.close()
        floatingWindow = nil
    }

    // MARK: - Hook Installation

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

    var body: some Scene {
        Settings {
            if let appState = AppDelegate.shared?.appState {
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
}

// MARK: - Floating Window Hover

/// Invisible tracking view that shows/hides the close button on window hover.
private final class FloatingWindowHoverTracker: NSView {
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.standardWindowButton(.closeButton)?.isHidden = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard let window = trackedWindow else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.standardWindowButton(.closeButton)?.isHidden = true
        }
    }
}

// MARK: - Menu Bar Rendering

/// Pure rendering functions for menu bar icon images.
/// Extracted from the old MenuBarLabel so they can be called from AppDelegate.
enum MenuBarRenderer {

    /// Draw a circular progress ring into the current graphics context.
    static func drawRing(
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
    static func makeMenuBarRep(size: NSSize) -> (NSBitmapImageRep, NSSize) {
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
    static func renderRingOnly(pct: CGFloat) -> NSImage? {
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
    /// Returns the image and the pill color (if any) so the caller can apply
    /// the background directly on the NSStatusBarButton's layer.
    static func renderStatusImage(
        approval: Int, waiting: Int, working: Int,
        useRedYellowMode: Bool,
        usagePct: CGFloat? = nil
    ) -> (NSImage, NSColor?)? {
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

        // No pill background drawn here — the caller sets it on the
        // NSStatusBarButton's layer so it fills the exact button bounds.

        let textY = (imageSize.height - textSize.height) / 2
        result.draw(at: NSPoint(x: hPad, y: textY))

        // Ring after the text
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
        return (image, pillColor)
    }
}
