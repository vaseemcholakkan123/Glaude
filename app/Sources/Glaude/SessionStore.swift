import Foundation

enum SessionState {
    case idle, working, needsYou, done
}

/// An edit's change, from the tool's structuredPatch: counts plus the hunks to draw.
struct FileDiff {
    struct Hunk { let oldStart: Int; let newStart: Int; let lines: [String] }
    let added: Int
    let removed: Int
    let hunks: [Hunk]
    let truncated: Bool
}

/// One plan rate-limit window (`five_hour`, `seven_day`, …), account-wide.
struct PlanLimit: Identifiable {
    let kind: String
    let percentUsed: Double
    let resetsAt: Date?
    var id: String { kind }

    var shortName: String {
        switch kind {
        case "five_hour": return "5h"
        case "seven_day": return "wk"
        case "seven_day_opus": return "wk Opus"
        default: return kind.replacingOccurrences(of: "_", with: " ")
        }
    }
}

struct ChatItem: Identifiable {
    enum Kind {
        case user(String)
        case assistant(String)
        case tool(symbol: String, text: String, diff: FileDiff?)
        case note(String)
        case summary(files: [String], commands: Int, added: Int, removed: Int)
    }
    let id = UUID()
    let kind: Kind
}

struct Question: Identifiable {
    struct Option: Hashable { let label: String; let description: String }
    var id: String { text }
    let text: String
    let header: String
    let options: [Option]
    let multiSelect: Bool
}

/// The card pinned above the reply box while a session waits on you.
struct PendingRequest: Identifiable {
    enum Kind {
        /// Allow/Deny in Glaude (the mod's `answerPermissions` option).
        case permission(tool: String, detail: String)
        case questions([Question])
        /// Something only the terminal can answer (a plan to approve, a permission prompt).
        case terminal(title: String, detail: String)
    }
    let id = UUID()
    let kind: Kind
    /// The mod's id for a request it is waiting on; nil for a terminal card.
    let key: String?
}

/// What a poll on a waiting request answers.
enum RequestOutcome {
    case answered([String: Any])
    case waiting
    case gone
}

struct Session: Identifiable {
    let id: String
    var pid: Int
    var cwd: String
    var state: SessionState = .idle
    var items: [ChatItem] = []
    var pending: PendingRequest?
    var turnFiles: [String] = []
    var turnCommands = 0
    var turnAdded = 0
    var turnRemoved = 0
    var unseenDone = false
    /// The claude process's terminal (`/dev/ttys003`) and where it was started: how the
    /// session's own terminal tab is found.
    var tty = ""
    var launchDir = ""
    /// How full the context window is, 0–100, after the last turn.
    var contextPercent: Double?
    /// When something last happened, for "jump to the latest session".
    var lastActivity = Date()
    /// Replies sent from Glaude that haven't come back through UserPromptSubmit yet.
    var echoes: [String] = []

    var name: String {
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        return last.isEmpty ? "session" : last
    }

    /// Path relative to the session's working directory, for compact display.
    func relative(_ path: String) -> String {
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

/// All live Claude Code sessions, fed by the glaude mod.
final class SessionStore: ObservableObject {
    /// How long a question or permission card waits before the terminal takes it.
    static let waitTimeout: TimeInterval = 120
    /// Every long-poll answers within this: the mod's fetches give up at 30 s.
    static let pollTimeout: TimeInterval = 25
    private static let maxItems = 300

    @Published private(set) var sessions: [Session] = []
    @Published var selectedID: String?
    @Published var chatVisible = false
    /// Sessions whose mod is polling for replies right now.
    @Published private(set) var replyable: Set<String> = []
    /// The plan's rate-limit windows, from the latest session that reported them.
    @Published private(set) var planLimits: [PlanLimit] = []
    /// Who notifies, from the mod's `notifications` option (`glaude`, `claude`, `off`).
    private(set) var notifyMode = "glaude"

    /// A session just finished a turn, or started waiting on you.
    var onDone: ((Session) -> Void)?
    var onNeedsYou: ((Session, String) -> Void)?

    private struct Waiting {
        let sessionID: String
        let pendingID: UUID
        var answer: [String: Any]?
        var poll: (id: UUID, respond: (RequestOutcome) -> Void)?
    }
    private var requests: [String: Waiting] = [:]
    private var replyWaiters: [String: (id: UUID, respond: (String?) -> Void)] = [:]
    private var replyQueue: [String: [String]] = [:]

    var selected: Session? {
        sessions.first { $0.id == selectedID } ?? sessions.first
    }

    var aggregateState: SessionState {
        if sessions.contains(where: { $0.pending != nil || $0.state == .needsYou }) { return .needsYou }
        if sessions.contains(where: { $0.state == .working }) { return .working }
        if sessions.contains(where: { $0.unseenDone }) { return .done }
        return .idle
    }

    /// The session's mod is polling, so a reply typed here reaches it.
    func canReply(_ session: Session) -> Bool {
        replyable.contains(session.id)
    }

    func select(_ id: String) {
        selectedID = id
        markSeen()
    }

    func markSeen() {
        guard chatVisible, let id = selected?.id else { return }
        update(id) { $0.unseenDone = false }
    }

    // MARK: Events from the mod

    func handleEvent(_ json: [String: Any]) {
        guard let sessionID = json["session_id"] as? String, !sessionID.isEmpty else { return }
        let event = json["hook_event_name"] as? String ?? ""

        if event == "SessionEnd" {
            endSession(sessionID)
            return
        }
        ensureSession(sessionID, pid: json["pid"] as? Int ?? 0, cwd: json["cwd"] as? String ?? "")
        absorbContext(json, sessionID: sessionID)

        switch event {
        case "UserPromptSubmit":
            let prompt = json["prompt"] as? String ?? ""
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            update(sessionID) { s in
                // Messages sent from Glaude are already in the chat.
                if let echo = s.echoes.firstIndex(of: trimmed) {
                    s.echoes.remove(at: echo)
                } else {
                    s.items.append(.init(kind: .user(prompt)))
                }
                Self.clearTerminalCard(&s)
                s.state = .working
                s.turnFiles = []
                s.turnCommands = 0
                s.turnAdded = 0
                s.turnRemoved = 0
                s.unseenDone = false
            }

        case "PostToolUse":
            update(sessionID) { s in
                s.items.append(Self.toolItem(json, session: &s))
                Self.clearTerminalCard(&s)
                if s.pending == nil { s.state = .working }
            }

        case "PermissionAsk":
            let tool = json["tool_name"] as? String ?? "tool"
            let input = json["tool_input"] as? [String: Any] ?? [:]
            showTerminalCard(sessionID, title: "Allow \(tool)?", detail: permissionDetail(tool: tool, input: input))

        case "ToolRunning":
            // The permission ask was answered (often by the auto-mode classifier).
            update(sessionID) { s in Self.clearTerminalCard(&s) }

        case "PlanReady":
            showTerminalCard(sessionID, title: "Plan ready for approval", detail: "Approve, edit or reject the plan in the terminal.")

        case "Stop":
            let text = json["last_assistant_message"] as? String
            let beingViewed = chatVisible && selected?.id == sessionID
            update(sessionID) { s in
                if let text, !text.isEmpty { s.items.append(.init(kind: .assistant(text))) }
                s.items.append(.init(kind: .summary(files: s.turnFiles, commands: s.turnCommands,
                                                    added: s.turnAdded, removed: s.turnRemoved)))
                Self.clearTerminalCard(&s)
                s.state = .done
                s.unseenDone = !beingViewed
            }
            if let s = session(sessionID) { onDone?(s) }

        default:
            break  // SessionStart: ensureSession above is all it needs
        }
    }

    /// The fields any event may carry: identity, notify mode, usage.
    private func absorbContext(_ json: [String: Any], sessionID: String) {
        if let mode = json["notify"] as? String, mode != notifyMode { notifyMode = mode }
        let tty = json["tty"] as? String ?? ""
        let launchDir = json["launch_dir"] as? String ?? ""
        let usage = json["usage"] as? [String: Any]
        update(sessionID) { s in
            if !tty.isEmpty, s.tty != tty { s.tty = tty }
            if !launchDir.isEmpty, s.launchDir != launchDir { s.launchDir = launchDir }
            if let percent = usage?["contextPercent"] as? Double { s.contextPercent = percent }
            s.lastActivity = Date()
        }
        if let limits = usage?["limits"] as? [[String: Any]], !limits.isEmpty {
            let iso = ISO8601DateFormatter()
            planLimits = limits.compactMap { l in
                guard let kind = l["kind"] as? String, let percent = l["percentUsed"] as? Double else { return nil }
                return PlanLimit(kind: kind, percentUsed: percent, resetsAt: (l["resetsAt"] as? String).flatMap(iso.date(from:)))
            }
        }
    }

    private func showTerminalCard(_ sessionID: String, title: String, detail: String) {
        guard let current = session(sessionID) else { return }
        if let old = current.pending, let key = old.key { finish(key, answer: nil) }
        update(sessionID) { s in
            s.pending = PendingRequest(kind: .terminal(title: title, detail: detail), key: nil)
            s.state = .needsYou
        }
        if let s = session(sessionID) { onNeedsYou?(s, title) }
    }

    private static func clearTerminalCard(_ s: inout Session) {
        guard case .terminal = s.pending?.kind else { return }
        s.pending = nil
        if s.state == .needsYou { s.state = .working }
    }

    private func endSession(_ sessionID: String) {
        for (key, waiting) in requests where waiting.sessionID == sessionID { finish(key, answer: nil) }
        replyWaiters.removeValue(forKey: sessionID)?.respond(nil)
        replyQueue[sessionID] = nil
        replyable.remove(sessionID)
        sessions.removeAll { $0.id == sessionID }
    }

    // MARK: Questions and permissions the mod waits on

    /// Puts up the card for a request the mod will poll for (`POST /wait`).
    func openRequest(key: String, json: [String: Any]) {
        guard requests[key] == nil, let sessionID = json["session_id"] as? String else { return }
        ensureSession(sessionID, pid: json["pid"] as? Int ?? 0, cwd: json["cwd"] as? String ?? "")
        let tool = json["tool_name"] as? String ?? "tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]

        let kind: PendingRequest.Kind
        let title: String
        if json["hook_event_name"] as? String == "Questions" {
            kind = .questions(parseQuestions(input))
            title = "Claude has a question"
        } else {
            kind = .permission(tool: tool, detail: permissionDetail(tool: tool, input: input))
            title = "Allow \(tool)?"
        }

        // A newer prompt replaces an older unanswered one, which falls back to the terminal.
        if let old = session(sessionID)?.pending, let oldKey = old.key { finish(oldKey, answer: nil) }

        let request = PendingRequest(kind: kind, key: key)
        requests[key] = Waiting(sessionID: sessionID, pendingID: request.id)
        update(sessionID) { s in
            s.pending = request
            s.state = .needsYou
        }
        if let s = session(sessionID) { onNeedsYou?(s, title) }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.waitTimeout) { [weak self] in
            self?.finish(key, answer: nil)
        }
    }

    /// One poll: answers at once if decided, else within `pollTimeout` with `.waiting`.
    /// Returns a cancel for when the poller goes away.
    func pollRequest(key: String, respond: @escaping (RequestOutcome) -> Void) -> () -> Void {
        guard var waiting = requests[key] else { respond(.gone); return {} }
        if let answer = waiting.answer {
            requests[key] = nil
            respond(.answered(answer))
            return {}
        }
        waiting.poll?.respond(.waiting)
        let pollID = UUID()
        waiting.poll = (pollID, respond)
        requests[key] = waiting
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollTimeout) { [weak self] in
            guard let self, self.requests[key]?.poll?.id == pollID else { return }
            self.requests[key]?.poll = nil
            respond(.waiting)
        }
        return { [weak self] in
            guard let self, self.requests[key]?.poll?.id == pollID else { return }
            self.requests[key]?.poll = nil
        }
    }

    /// The mod stopped waiting (answered in the terminal, interrupted, or gave up).
    func cancelRequest(key: String) {
        finish(key, answer: nil)
    }

    func answerPermission(_ request: PendingRequest, allow: Bool) {
        guard let key = request.key else { return }
        finish(key, answer: ["decision": allow ? "allow" : "deny"])
    }

    func answerQuestions(_ request: PendingRequest, answers: [String: String]) {
        guard let key = request.key else { return }
        finish(key, answer: ["answers": answers])
    }

    /// Leave the prompt to the terminal: the mod lets Claude Code ask there.
    func answerInTerminal(_ request: PendingRequest) {
        guard let key = request.key else { return }
        finish(key, answer: nil)
    }

    /// Settles a request: hands `answer` to the poller (or keeps it for the next poll);
    /// nil means no answer, and the request is gone.
    private func finish(_ key: String, answer: [String: Any]?) {
        guard var waiting = requests[key] else { return }
        if let index = sessions.firstIndex(where: { $0.pending?.id == waiting.pendingID }) {
            sessions[index].pending = nil
            if sessions[index].state == .needsYou { sessions[index].state = .working }
        }
        if let answer, waiting.poll == nil {
            waiting.answer = answer  // the mod is between polls: the next one picks it up
            requests[key] = waiting
            return
        }
        requests[key] = nil
        waiting.poll?.respond(answer.map { .answered($0) } ?? .gone)
    }

    // MARK: Replies typed in Glaude

    /// A reply poll means the session's mod is alive; the poll also names a session we
    /// may not have heard from yet (just after /clear).
    func replyPollArrived(session sessionID: String, cwd: String, pid: Int) {
        guard !sessionID.isEmpty else { return }
        ensureSession(sessionID, pid: pid, cwd: cwd)
        if !replyable.contains(sessionID) { replyable.insert(sessionID) }
    }

    func replyPoll(session sessionID: String, respond: @escaping (String?) -> Void) -> () -> Void {
        if var queue = replyQueue[sessionID], !queue.isEmpty {
            let text = queue.removeFirst()
            replyQueue[sessionID] = queue
            respond(text)
            return {}
        }
        let waiterID = UUID()
        replyWaiters[sessionID]?.respond(nil)
        replyWaiters[sessionID] = (waiterID, respond)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollTimeout) { [weak self] in
            guard let self, self.replyWaiters[sessionID]?.id == waiterID else { return }
            self.replyWaiters[sessionID] = nil
            respond(nil)
        }
        return { [weak self] in
            // The mod went away mid-poll (session closed, or the mod reloaded).
            guard let self, self.replyWaiters[sessionID]?.id == waiterID else { return }
            self.replyWaiters[sessionID] = nil
            self.replyable.remove(sessionID)
        }
    }

    func send(_ text: String, to sessionID: String) {
        guard let s = session(sessionID), canReply(s) else { return }
        update(sessionID) { s in
            s.items.append(.init(kind: .user(text)))
            s.echoes.append(text)
            s.state = .working
            s.turnFiles = []
            s.turnCommands = 0
            s.turnAdded = 0
            s.turnRemoved = 0
        }
        if let waiter = replyWaiters.removeValue(forKey: sessionID) {
            waiter.respond(text)
        } else {
            replyQueue[sessionID, default: []].append(text)
        }
    }

    // MARK: Helpers

    /// Snapshot for `GET /state` (debugging).
    func debugState() -> [String: Any] {
        [
            "aggregate": "\(aggregateState)",
            "sessions": sessions.map { s -> [String: Any] in
                [
                    "id": s.id, "pid": s.pid, "name": s.name, "state": "\(s.state)",
                    "pending": s.pending.map { p -> String in
                        switch p.kind {
                        case .permission(let tool, _): return "permission:\(tool)"
                        case .questions: return "questions"
                        case .terminal(let title, _): return "terminal:\(title)"
                        }
                    } ?? NSNull(),
                    "canReply": canReply(s), "unseenDone": s.unseenDone,
                    "tty": s.tty, "launchDir": s.launchDir, "contextPercent": s.contextPercent ?? NSNull(),
                    "turnFiles": s.turnFiles, "turnCommands": s.turnCommands,
                    "items": s.items.map { item -> String in
                        switch item.kind {
                        case .user(let t): return "user: \(t.prefix(60))"
                        case .assistant(let t): return "assistant: \(t.prefix(60))"
                        case .tool(let sym, let t, let d): return "tool[\(sym)]: \(t)" + (d.map { " +\($0.added) −\($0.removed)" } ?? "")
                        case .note(let t): return "note: \(t)"
                        case .summary(let f, let c, let a, let r): return "summary: \(f.count) files, \(c) cmds, +\(a) −\(r)"
                        }
                    },
                ]
            },
            "waitingRequests": requests.count,
            "notifyMode": notifyMode,
            "planLimits": planLimits.map { "\($0.kind) \($0.percentUsed)%" },
        ]
    }

    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    private func update(_ id: String, _ change: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
        if sessions[index].items.count > Self.maxItems {
            sessions[index].items.removeFirst(sessions[index].items.count - Self.maxItems)
        }
    }

    private func ensureSession(_ id: String, pid: Int, cwd: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            if pid != 0, sessions[index].pid != pid { sessions[index].pid = pid }
            if sessions[index].cwd.isEmpty, !cwd.isEmpty { sessions[index].cwd = cwd }
            return
        }
        sessions.append(Session(id: id, pid: pid, cwd: cwd))
    }

    private static func toolItem(_ json: [String: Any], session s: inout Session) -> ChatItem {
        let tool = json["tool_name"] as? String ?? "Tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let path = (input["file_path"] ?? input["notebook_path"]) as? String

        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let rel = s.relative(path ?? "")
            if !s.turnFiles.contains(rel) { s.turnFiles.append(rel) }
            let diff = Self.fileDiff(json)
            s.turnAdded += diff?.added ?? 0
            s.turnRemoved += diff?.removed ?? 0
            return .init(kind: .tool(symbol: "pencil", text: rel, diff: diff))
        case "Bash":
            s.turnCommands += 1
            let command = (input["command"] as? String ?? "").components(separatedBy: "\n").first ?? ""
            return .init(kind: .tool(symbol: "terminal", text: command, diff: nil))
        case "Read":
            return .init(kind: .tool(symbol: "doc.text", text: s.relative(path ?? ""), diff: nil))
        case "Grep", "Glob":
            return .init(kind: .tool(symbol: "magnifyingglass", text: input["pattern"] as? String ?? tool, diff: nil))
        case "WebFetch", "WebSearch":
            return .init(kind: .tool(symbol: "globe", text: (input["url"] ?? input["query"]) as? String ?? tool, diff: nil))
        case "Task", "Agent":
            return .init(kind: .tool(symbol: "person.2", text: input["description"] as? String ?? "Agent", diff: nil))
        default:
            let parts = tool.components(separatedBy: "__")
            let label = parts.count >= 3 && parts[0] == "mcp" ? "\(parts[1]) · \(parts[2...].joined(separator: "__"))" : tool
            return .init(kind: .tool(symbol: "wrench.and.screwdriver", text: label, diff: nil))
        }
    }

    /// The mod's `patch`, `added` and `removed` for an edit; nil when it sent none.
    private static func fileDiff(_ json: [String: Any]) -> FileDiff? {
        guard let added = json["added"] as? Int, let removed = json["removed"] as? Int else { return nil }
        let hunks = (json["patch"] as? [[String: Any]] ?? []).map { h in
            FileDiff.Hunk(oldStart: h["oldStart"] as? Int ?? 0, newStart: h["newStart"] as? Int ?? 0,
                          lines: h["lines"] as? [String] ?? [])
        }
        return FileDiff(added: added, removed: removed, hunks: hunks, truncated: json["patch_truncated"] as? Bool ?? false)
    }

    private func permissionDetail(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let path = (input["file_path"] ?? input["notebook_path"]) as? String { return path }
        if let url = input["url"] as? String { return url }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private func parseQuestions(_ input: [String: Any]) -> [Question] {
        (input["questions"] as? [[String: Any]] ?? []).map { q in
            Question(
                text: q["question"] as? String ?? "",
                header: q["header"] as? String ?? "",
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    .init(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                },
                multiSelect: q["multiSelect"] as? Bool ?? false
            )
        }
    }
}
