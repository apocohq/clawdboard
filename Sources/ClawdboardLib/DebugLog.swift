import Foundation

/// Logs a message only in DEBUG builds. Compiles to a no-op in release.
@inlinable
public func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        NSLog("%@", message())
    #endif
}
