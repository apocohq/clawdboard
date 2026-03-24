import Foundation
import SQLite3

/// Reads hidden session IDs from VS Code-family IDE global state databases.
///
/// When a user deletes a session in VS Code's Claude sidebar (trash icon),
/// the extension adds the session ID to `hiddenSessionIds` in its global state
/// (stored in a SQLite DB). The Claude process often stays alive, so neither
/// SessionEnd hooks nor PID liveness checks clean up the state file.
///
/// This provides a definitive cleanup signal: if VS Code says a session is
/// hidden, its state file can be safely removed.
///
/// Discovers all VS Code variants (Code, Insiders, Cursor, Windsurf, etc.)
/// automatically by scanning Application Support for the standard
/// `User/globalStorage/state.vscdb` layout.
public enum VSCodeHiddenSessions {

    /// The key under which the Claude Code extension stores its global state.
    /// This is the `publisher.name` identifier from the extension's package.json.
    private static let extensionStateKey = "Anthropic.claude-code"

    /// Swift equivalent of C's SQLITE_TRANSIENT — tells SQLite to copy the bound value
    /// immediately. The C macro `((sqlite3_destructor_type)-1)` can't be auto-imported.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Cached result to avoid scanning Application Support on every 3-second poll.
    /// Thread safety: these are only accessed from SessionStateWatcher's serial ioQueue.
    /// If called from multiple threads, add a lock.
    private static var cachedHiddenIDs = Set<String>()
    private static var cacheTimestamp: Date = .distantPast
    private static let cacheLifetime: TimeInterval = 30.0

    /// Returns all session IDs that users have hidden/deleted across all
    /// VS Code-family IDEs on this machine. Cached for 30 seconds.
    public static func allHiddenSessionIDs() -> Set<String> {
        let now = Date()
        if now.timeIntervalSince(cacheTimestamp) < cacheLifetime {
            return cachedHiddenIDs
        }

        var result = Set<String>()
        for dbPath in discoverStateDBPaths() {
            result.formUnion(readHiddenIDs(from: dbPath))
        }

        cachedHiddenIDs = result
        cacheTimestamp = now
        debugLog("[IDEHidden] Refreshed: \(result.count) hidden session IDs")
        return result
    }

    /// Discover VS Code-family global state databases by scanning
    /// `~/Library/Application Support/*/User/globalStorage/state.vscdb`.
    private static func discoverStateDBPaths() -> [String] {
        guard
            let appSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return [] }

        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: appSupportURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )
        else { return [] }

        return entries.compactMap { dir in
            let dbURL =
                dir
                .appendingPathComponent("User")
                .appendingPathComponent("globalStorage")
                .appendingPathComponent("state.vscdb")
            return FileManager.default.fileExists(atPath: dbURL.path) ? dbURL.path : nil
        }
    }

    /// Read `hiddenSessionIds` from a single VS Code global state database.
    private static func readHiddenIDs(from dbPath: String) -> Set<String> {
        var db: OpaquePointer?
        guard
            sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK
        else {
            debugLog("[IDEHidden] Failed to open DB: \(dbPath)")
            return []
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "SELECT value FROM ItemTable WHERE key = ?"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, extensionStateKey, -1, sqliteTransient)

        guard sqlite3_step(stmt) == SQLITE_ROW,
            let cString = sqlite3_column_text(stmt, 0)
        else { return [] }

        guard let data = String(cString: cString).data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ids = dict["hiddenSessionIds"] as? [String]
        else {
            debugLog("[IDEHidden] Failed to parse hiddenSessionIds from: \(dbPath)")
            return []
        }

        return Set(ids)
    }
}
