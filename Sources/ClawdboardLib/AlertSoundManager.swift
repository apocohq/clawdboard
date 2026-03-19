import AVFoundation
import Foundation

/// Manages an optional alert sound that plays when any session transitions to "needs approval".
public class AlertSoundManager {
    public static let shared = AlertSoundManager()

    private static let bookmarkKey = "alertSoundBookmark"
    private var player: AVAudioPlayer?

    private init() {}

    /// The resolved URL from the stored security-scoped bookmark, or nil if not set.
    public var soundFileURL: URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &isStale)
        else { return nil }
        if isStale {
            // Re-save a fresh bookmark if possible
            if let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
            }
        }
        return url
    }

    /// The display name of the configured sound file.
    public var soundFileName: String? {
        soundFileURL?.lastPathComponent
    }

    /// Store a new sound file URL as a security-scoped bookmark.
    public func setSoundFile(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    /// Remove the configured sound file.
    public func clearSoundFile() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        player?.stop()
        player = nil
    }

    /// Play the configured alert sound. No-op if no sound is configured.
    public func play() {
        guard let url = soundFileURL else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch {
            // Silently fail — sound is a nice-to-have
        }
    }
}
