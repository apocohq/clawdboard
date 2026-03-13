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
        MenuBarExtra {
            PanelView()
                .environment(appState)
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// Menu bar label rendered as an NSImage so we get proper SF Symbols + text.
/// SwiftUI MenuBarExtra labels don't reliably render complex view hierarchies,
/// but a single Image backed by a rendered NSImage works perfectly.
struct MenuBarLabel: View {
    let appState: AppState
    @AppStorage("useRedYellowMode") private var useRedYellowMode = true

    var body: some View {
        let approval = appState.needsApprovalCount
        let waiting = appState.waitingCount
        let working = appState.workingCount

        if approval == 0 && waiting == 0 && working == 0 {
            Image(systemName: "terminal")
        } else {
            if let image = Self.renderStatusImage(
                approval: approval, waiting: waiting, working: working,
                useRedYellowMode: useRedYellowMode
            ) {
                Image(nsImage: image)
            }
        }
    }

    /// Render SF Symbols + counts into an NSImage suitable for the menu bar.
    /// Pill background color depends on state and user's color mode preference.
    private static func renderStatusImage(
        approval: Int, waiting: Int, working: Int,
        useRedYellowMode: Bool
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
        let foreground: NSColor = hasPill ? (needsDarkText ? .black : .white) : .controlTextColor
        let dotForeground: NSColor =
            hasPill
            ? (needsDarkText ? .black.withAlphaComponent(0.5) : .white.withAlphaComponent(0.7))
            : .secondaryLabelColor

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
        let imageSize = NSSize(
            width: ceil(textSize.width) + hPad * 2,
            height: menuBarHeight
        )
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = imageSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        if let color = pillColor {
            let pillRect = NSRect(origin: .zero, size: imageSize)
            let path = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
            color.setFill()
            path.fill()
        }

        let textY = (imageSize.height - textSize.height) / 2
        result.draw(at: NSPoint(x: hPad, y: textY))

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: imageSize)
        image.addRepresentation(rep)
        image.isTemplate = !hasPill
        return image
    }
}
