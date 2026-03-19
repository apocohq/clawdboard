import Foundation

private class BundleMarker {}

extension Foundation.Bundle {
    /// Custom resource bundle accessor that works in both SPM development
    /// builds and proper .app bundles.
    ///
    /// SPM's auto-generated accessor only checks Bundle.main.bundleURL (the
    /// .app root), but macOS codesigning requires all content inside Contents/.
    /// This accessor checks Contents/Resources/ first (correct for .app bundles),
    /// then falls back to the executable directory (correct for `swift run`).
    static let module: Bundle = {
        let bundleName = "Clawdboard_ClawdboardLib"

        let candidates = [
            // .app bundle: Contents/Resources/
            Bundle.main.resourceURL,
            // swift run / swift test: next to the executable
            Bundle.main.bundleURL,
            // Framework / plugin contexts
            Bundle(for: BundleMarker.self).resourceURL,
        ]

        for candidate in candidates {
            guard let dir = candidate else { continue }
            let bundlePath = dir.appendingPathComponent(bundleName + ".bundle")
            if let bundle = Bundle(path: bundlePath.path) {
                return bundle
            }
        }

        fatalError("Could not find resource bundle \(bundleName).bundle")
    }()
}
