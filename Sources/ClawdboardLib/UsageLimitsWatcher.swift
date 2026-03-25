import Foundation

/// Fetches usage limits from the Claude API using the OAuth token from the macOS Keychain
/// (falling back to ~/.claude/.credentials.json). Caches results to ~/.clawdboard/usage-limits.json
/// to avoid rate limits across restarts. Polls every 5 minutes.
public class UsageLimitsWatcher {
    private static let pollInterval: TimeInterval = 300
    private static let minFetchInterval: TimeInterval = 300
    private static let apiURL = "https://api.anthropic.com/api/oauth/usage"
    private static let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")
    private static let cacheFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".clawdboard/usage-limits.json")

    private var timer: Timer?
    private let onChange: (UsageLimitsData?) -> Void
    private let onError: (String?) -> Void

    public init(
        onChange: @escaping (UsageLimitsData?) -> Void,
        onError: @escaping (String?) -> Void = { _ in }
    ) {
        self.onChange = onChange
        self.onError = onError
    }

    public func start() {
        debugLog("[UsageLimits] Starting watcher, cache file: \(Self.cacheFile.path)")
        // Load cached data immediately (no API call needed)
        if let cached = Self.loadCache() {
            debugLog("[UsageLimits] Loaded cache, 5h=\(cached.fiveHour.utilization)%")
            onChange(cached)
        } else {
            debugLog("[UsageLimits] No cache found")
        }
        // Fetch fresh if cache is stale
        pollIfNeeded()
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval, repeats: true
        ) { [weak self] _ in
            self?.pollIfNeeded()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        fetchFromAPI()
    }

    // MARK: - Credentials

    private static func readAccessToken() -> String? {
        // Try macOS Keychain first (Claude Code >=2.x stores tokens here)
        if let token = readAccessTokenFromKeychain() {
            return token
        }
        // Fall back to credentials file (older Claude Code versions)
        if let token = readAccessTokenFromFile() {
            return token
        }
        return nil
    }

    private static func readAccessTokenFromKeychain() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            debugLog("[UsageLimits] Keychain: failed to run security CLI: \(error)")
            return nil
        }
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            debugLog(
                "[UsageLimits] Keychain: security exited \(process.terminationStatus): \(errStr.prefix(200))"
            )
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let jsonString = String(data: output, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !jsonString.isEmpty
        else {
            debugLog("[UsageLimits] Keychain: security returned empty output")
            return nil
        }
        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            debugLog("[UsageLimits] Keychain: could not parse output: \(jsonString.prefix(200))")
            return nil
        }
        // Keychain stores same structure as credentials file: {claudeAiOauth: {accessToken: ...}}
        let token: String?
        if let oauth = json["claudeAiOauth"] as? [String: Any] {
            token = oauth["accessToken"] as? String
        } else {
            token = json["accessToken"] as? String
        }
        guard let token, !token.isEmpty else {
            debugLog("[UsageLimits] Keychain: no accessToken in JSON")
            return nil
        }
        return token
    }

    private static func readAccessTokenFromFile() -> String? {
        guard let data = try? Data(contentsOf: credentialsFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            return nil
        }
        return token
    }

    // MARK: - Cache

    private static func loadCache() -> UsageLimitsData? {
        guard let data = try? Data(contentsOf: cacheFile),
            let cached = try? JSONDecoder().decode(CachedUsageLimits.self, from: data)
        else {
            return nil
        }
        return Self.buildFromCached(cached)
    }

    private static func saveCache(_ response: UsageLimitsResponse) {
        let cached = CachedUsageLimits(
            fiveHour: response.fiveHour,
            sevenDay: response.sevenDay,
            fetchedAt: ISO8601DateFormatter().string(from: Date())
        )
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: cacheFile, options: .atomic)
        }
    }

    private static func cacheAge() -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
            let modified = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        return Date().timeIntervalSince(modified)
    }

    // MARK: - Polling

    private func pollIfNeeded() {
        let age = Self.cacheAge()
        debugLog("[UsageLimits] pollIfNeeded, cacheAge=\(age.map { String(Int($0)) } ?? "nil")s")
        // Skip API call if cache is fresh
        if let age = age, age < Self.minFetchInterval {
            // Recalculate from cache (average/estimated change over time)
            if let cached = Self.loadCache() {
                DispatchQueue.main.async { self.onChange(cached) }
            }
            return
        }
        fetchFromAPI()
    }

    private func fetchFromAPI() {
        debugLog("[UsageLimits] Fetching from API...")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let token = Self.readAccessToken() else {
                debugLog("[UsageLimits] No access token found in credentials file")
                DispatchQueue.main.async {
                    self.onError("No OAuth token found. Sign in to claude.ai.")
                    // Still serve cached data if available
                    self.onChange(Self.loadCache())
                }
                return
            }

            guard let url = URL(string: Self.apiURL) else { return }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("clawdboard/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    debugLog("[UsageLimits] Network error: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.onError("Network error: \(error.localizedDescription)")
                        self.onChange(Self.loadCache())
                    }
                    return
                }
                guard let httpResp = response as? HTTPURLResponse,
                    httpResp.statusCode == 200, let data = data
                else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    debugLog("[UsageLimits] API returned \(status), serving cache")
                    if let data = data, let body = String(data: data, encoding: .utf8) {
                        debugLog("[UsageLimits] Body: \(body.prefix(200))")
                    }
                    DispatchQueue.main.async {
                        self.onError("API error (HTTP \(status))")
                        self.onChange(Self.loadCache())
                    }
                    return
                }

                do {
                    let limits = try JSONDecoder().decode(UsageLimitsResponse.self, from: data)
                    debugLog(
                        "[UsageLimits] API success: 5h=\(limits.fiveHour.utilization)% 7d=\(limits.sevenDay.utilization)%"
                    )
                    Self.saveCache(limits)
                    let now = Date()
                    let result = UsageLimitsData(
                        fiveHour: Self.buildWindow(
                            utilization: limits.fiveHour.utilization,
                            resetsAt: limits.fiveHour.resetsAt,
                            windowHours: 5, now: now
                        ),
                        sevenDay: Self.buildWindow(
                            utilization: limits.sevenDay.utilization,
                            resetsAt: limits.sevenDay.resetsAt,
                            windowHours: 168, now: now
                        ),
                        updatedAt: now
                    )
                    DispatchQueue.main.async {
                        self.onError(nil)
                        self.onChange(result)
                    }
                } catch {
                    debugLog("[UsageLimits] Decode error: \(error)")
                    DispatchQueue.main.async {
                        self.onError("Failed to decode API response")
                        self.onChange(Self.loadCache())
                    }
                }
            }
            task.resume()
        }
    }

    // MARK: - Calculations

    private static func buildFromCached(_ cached: CachedUsageLimits) -> UsageLimitsData {
        let now = Date()
        return UsageLimitsData(
            fiveHour: buildWindow(
                utilization: cached.fiveHour.utilization,
                resetsAt: cached.fiveHour.resetsAt,
                windowHours: 5, now: now
            ),
            sevenDay: buildWindow(
                utilization: cached.sevenDay.utilization,
                resetsAt: cached.sevenDay.resetsAt,
                windowHours: 168, now: now
            ),
            updatedAt: ISO8601DateFormatter().date(from: cached.fetchedAt) ?? now
        )
    }

    private static func buildWindow(
        utilization: Double, resetsAt: String, windowHours: Int, now: Date
    ) -> UsageLimitWindow {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resetDate =
            formatter.date(from: resetsAt)
            ?? ISO8601DateFormatter().date(from: resetsAt) ?? now

        let windowMs = Double(windowHours) * 3600 * 1000
        let startDate = resetDate.addingTimeInterval(-Double(windowHours) * 3600)
        let elapsedMs = now.timeIntervalSince(startDate) * 1000

        let average: Double
        if elapsedMs <= 0 {
            average = 0
        } else if elapsedMs >= windowMs {
            average = 100
        } else {
            average = (elapsedMs / windowMs) * 100
        }

        let estimated: Double?
        if utilization <= 0 || elapsedMs <= 0 {
            estimated = utilization > 0 ? utilization : 0
        } else if elapsedMs >= windowMs {
            estimated = utilization
        } else {
            let elapsedPct = (elapsedMs / windowMs) * 100
            estimated = (utilization / elapsedPct) * 100
        }

        let remainingSeconds = max(resetDate.timeIntervalSince(now), 0)

        return UsageLimitWindow(
            utilization: round(utilization * 10) / 10,
            average: round(average * 10) / 10,
            estimated: round((estimated ?? 0) * 10) / 10,
            resetsAt: resetDate,
            remainingSeconds: remainingSeconds
        )
    }

    deinit {
        stop()
    }
}

// MARK: - Cache Model

private struct CachedUsageLimits: Codable {
    let fiveHour: LimitWindowResponse
    let sevenDay: LimitWindowResponse
    let fetchedAt: String
}
