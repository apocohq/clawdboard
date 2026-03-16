import Foundation

/// Polls Firestore for encrypted cloud session state, decrypts with the local private key,
/// and delivers AgentSession updates. Follows the same pattern as RemoteSessionWatcher.
public class CloudSessionWatcher {
    private var timer: Timer?
    private var isEnabled = false
    private let onChange: (_ sessions: [AgentSession]) -> Void

    /// Default Firebase project — used unless overridden.
    public static let defaultFirebaseProject = "clawdboard-cloud"

    /// Polling interval for cloud sessions (seconds).
    public var pollInterval: TimeInterval = 10

    public init(onChange: @escaping (_ sessions: [AgentSession]) -> Void) {
        self.onChange = onChange
    }

    /// Start polling Firestore for cloud sessions.
    public func start() {
        guard !isEnabled else { return }
        guard KeychainManager.shared.hasKeypair else { return }
        isEnabled = true
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
            [weak self] _ in
            self?.poll()
        }
    }

    /// Stop polling.
    public func stop() {
        timer?.invalidate()
        timer = nil
        isEnabled = false
    }

    /// Restart with current settings (e.g. after keypair generation).
    public func restart() {
        stop()
        start()
    }

    // MARK: - Firestore Polling

    private func poll() {
        guard let channelId = KeychainManager.shared.channelId else { return }

        let project = Self.defaultFirebaseProject
        // Query all documents in the channel's sessions collection
        let urlString =
            "https://firestore.googleapis.com/v1/projects/\(project)/databases/(default)/documents/channels/\(channelId)/sessions"

        guard let url = URL(string: urlString) else { return }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }

            guard let data = data, error == nil,
                let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                DispatchQueue.main.async {
                    self.onChange([])
                }
                return
            }

            let sessions = self.parseFirestoreResponse(data)
            DispatchQueue.main.async {
                self.onChange(sessions)
            }
        }
        task.resume()
    }

    /// Parse Firestore REST API response and decrypt session blobs.
    private func parseFirestoreResponse(_ data: Data) -> [AgentSession] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let documents = json["documents"] as? [[String: Any]]
        else {
            return []
        }

        var sessions: [AgentSession] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for doc in documents {
            guard let fields = doc["fields"] as? [String: Any],
                let blobField = fields["blob"] as? [String: Any],
                let blobBase64 = blobField["stringValue"] as? String,
                let blobData = Data(base64Encoded: blobBase64)
            else { continue }

            guard let decrypted = try? KeychainManager.shared.decrypt(blob: blobData),
                var session = try? decoder.decode(AgentSession.self, from: decrypted)
            else { continue }

            // Tag as cloud session
            session.isCloudSession = true
            sessions.append(session)
        }

        return sessions
    }

    deinit {
        stop()
    }
}
