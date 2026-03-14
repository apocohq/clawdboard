import Foundation

/// Polls remote machines via SSH to read their ~/.clawdboard/sessions/*.json state files.
/// Each enabled RemoteHost is polled on its own timer. Results are merged with local sessions
/// in AppState.
public class RemoteSessionWatcher {
    private var timers: [String: Timer] = [:]
    private var hosts: [RemoteHost] = []
    private let onChange: (_ host: String, _ sessions: [AgentSession]) -> Void

    /// Callback fires per-host with the sessions discovered on that host.
    public init(onChange: @escaping (_ host: String, _ sessions: [AgentSession]) -> Void) {
        self.onChange = onChange
    }

    /// Update the set of remote hosts to watch. Starts/stops timers as needed.
    public func updateHosts(_ newHosts: [RemoteHost]) {
        let enabledHosts = newHosts.filter(\.isEnabled)
        let oldIds = Set(hosts.map(\.host))
        let newIds = Set(enabledHosts.map(\.host))

        // Stop timers for removed/disabled hosts
        for hostId in oldIds.subtracting(newIds) {
            timers[hostId]?.invalidate()
            timers.removeValue(forKey: hostId)
            // Clear sessions for removed hosts
            onChange(hostId, [])
        }

        // Start or update timers for new/changed hosts
        for host in enabledHosts {
            let existingHost = hosts.first { $0.host == host.host }
            let intervalChanged = existingHost?.pollInterval != host.pollInterval
            let isNew = !oldIds.contains(host.host)

            if isNew || intervalChanged {
                timers[host.host]?.invalidate()
                startTimer(for: host)
            }
        }

        hosts = enabledHosts
    }

    public func stop() {
        for timer in timers.values {
            timer.invalidate()
        }
        timers.removeAll()
        hosts.removeAll()
    }

    // MARK: - Private

    private func startTimer(for host: RemoteHost) {
        // Fire immediately, then repeat
        pollHost(host)
        let timer = Timer.scheduledTimer(
            withTimeInterval: host.pollInterval, repeats: true
        ) { [weak self] _ in
            self?.pollHost(host)
        }
        timers[host.host] = timer
    }

    private func pollHost(_ host: RemoteHost) {
        let hostId = host.host
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "ConnectTimeout=5",
            "-o", "BatchMode=yes",  // No interactive prompts — fail if key auth doesn't work
            hostId,
            // Read all session JSON files, output as a JSON array.
            // If no files exist, outputs "[]".
            "python3 -c \"\nimport json, glob, os\nfiles = glob.glob(os.path.expanduser('~/.clawdboard/sessions/*.json'))\nsessions = []\nfor f in files:\n    try:\n        sessions.append(json.load(open(f)))\n    except: pass\nprint(json.dumps(sessions))\n\"",
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        // Run SSH asynchronously to avoid blocking the main thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try task.run()
                task.waitUntilExit()

                guard task.terminationStatus == 0 else {
                    DispatchQueue.main.async {
                        self?.onChange(hostId, [])
                    }
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                var sessions = (try? decoder.decode([AgentSession].self, from: data)) ?? []

                // Tag each session with the remote host and skip PID liveness (can't check remotely)
                sessions = sessions.map { session in
                    var s = session
                    s.remoteHost = hostId
                    return s
                }

                DispatchQueue.main.async {
                    self?.onChange(hostId, sessions)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.onChange(hostId, [])
                }
            }
        }
    }

    /// Check if hooks are installed on a remote host by looking for the state files directory
    /// and the hook script.
    public static func checkRemoteHooks(
        host: String, completion: @escaping (RemoteHookStatus) -> Void
    ) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "ConnectTimeout=5",
            "-o", "BatchMode=yes",
            host,
            "test -f ~/.clawdboard/hooks/clawdboard-hook.py && echo installed || echo missing",
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .utility).async {
            do {
                try task.run()
                task.waitUntilExit()

                guard task.terminationStatus == 0 else {
                    DispatchQueue.main.async { completion(.error) }
                    return
                }

                let output =
                    String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let status: RemoteHookStatus = output == "installed" ? .installed : .notInstalled
                DispatchQueue.main.async { completion(status) }
            } catch {
                DispatchQueue.main.async { completion(.error) }
            }
        }
    }

    /// Install hooks on a remote host by copying the hook script and merging into Claude settings.
    public static func installRemoteHooks(
        host: String, completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let hookScript = HookManager.remoteHookScript()

        let installCommand = """
            mkdir -p ~/.clawdboard/hooks ~/.clawdboard/sessions && \
            cat > ~/.clawdboard/hooks/clawdboard-hook.py << 'CLAWDBOARD_HOOK_EOF'
            \(hookScript)
            CLAWDBOARD_HOOK_EOF
            chmod 755 ~/.clawdboard/hooks/clawdboard-hook.py && \
            python3 -c "
            import json, os
            settings_path = os.path.expanduser('~/.claude/settings.json')
            os.makedirs(os.path.dirname(settings_path), exist_ok=True)
            settings = {}
            if os.path.isfile(settings_path):
                try:
                    settings = json.load(open(settings_path))
                except: pass
            hooks = settings.get('hooks', {})
            hook_cmd = 'python3 ~/.clawdboard/hooks/clawdboard-hook.py'
            events = ['SessionStart','PostToolUse','PermissionRequest','Stop','UserPromptSubmit','SessionEnd','SubagentStart','SubagentStop']
            for event in events:
                entries = [e for e in hooks.get(event, []) if not any('clawdboard' in h.get('command','') for h in e.get('hooks',[]))]
                entries.append({'matcher':'*','hooks':[{'type':'command','command':hook_cmd,'timeout':10}]})
                hooks[event] = entries
            notifs = [e for e in hooks.get('Notification', []) if not any('clawdboard' in h.get('command','') for h in e.get('hooks',[]))]
            for m in ['idle_prompt','permission_prompt']:
                notifs.append({'matcher':m,'hooks':[{'type':'command','command':hook_cmd+' '+m,'timeout':10}]})
            hooks['Notification'] = notifs
            settings['hooks'] = hooks
            with open(settings_path, 'w') as f:
                json.dump(settings, f, indent=2, sort_keys=True)
            print('ok')
            "
            """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            host,
            installCommand,
        ]

        let pipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errPipe

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try task.run()
                task.waitUntilExit()

                if task.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(.success(())) }
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg =
                        String(data: errData, encoding: .utf8) ?? "SSH command failed"
                    DispatchQueue.main.async {
                        completion(
                            .failure(
                                NSError(
                                    domain: "RemoteHooks", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: errMsg])))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    deinit {
        stop()
    }
}
