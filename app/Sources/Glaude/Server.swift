import Foundation
import Network

/// A parsed HTTP/1.1 request.
struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]  // lowercased names
    var body: Data

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

/// One client connection. Requests may be answered later (long-poll); `onClose`
/// fires if the client goes away before we respond.
final class HTTPConnection {
    private let conn: NWConnection
    private var buffer = Data()
    private var sentContinue = false
    private var finished = false
    var onClose: (() -> Void)?
    var onFinish: (() -> Void)?

    init(_ conn: NWConnection) { self.conn = conn }

    func start(_ handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.closed()
            default: break
            }
        }
        conn.start(queue: .main)
        receive(handler)
    }

    private func receive(_ handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let request = self.parse() {
                handler(request, self)
                self.watchForClose()
            } else if isComplete || error != nil {
                self.conn.cancel()
            } else {
                self.receive(handler)
            }
        }
    }

    /// Keeps a read pending so we notice when a long-polling client disconnects.
    private func watchForClose() {
        guard !finished else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self, !self.finished else { return }
            if isComplete || error != nil { self.conn.cancel() } else { self.watchForClose() }
        }
    }

    private func parse() -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        if buffer.count - bodyStart < length {
            if headers["expect"]?.lowercased() == "100-continue", !sentContinue {
                sentContinue = true
                conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
            return nil
        }

        let components = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(
            method: String(parts[0]),
            path: components?.path ?? String(parts[1]),
            query: query,
            headers: headers,
            body: buffer[bodyStart..<(bodyStart + length)]
        )
    }

    func respond(_ status: Int, json: Any? = nil) {
        guard !finished else { return }
        finished = true
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reason = [200: "OK", 202: "Accepted", 204: "No Content", 403: "Forbidden", 404: "Not Found"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        let conn = self.conn
        conn.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
        onFinish?()
    }

    private func closed() {
        guard !finished else { return }
        finished = true
        onClose?()
        onFinish?()
    }
}

/// Localhost-only HTTP server that receives the mod's events and serves its long-polls.
final class GlaudeServer {
    static let preferredPort: UInt16 = 47821

    private let token: String
    private let store: SessionStore
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    init(token: String, store: SessionStore) {
        self.token = token
        self.store = store
    }

    func start(port: UInt16 = GlaudeServer.preferredPort) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: params) else {
            if port != 0 { start(port: 0) }
            return
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                if let actual = listener?.port?.rawValue { GlaudeFiles.writePort(actual) }
            case .failed(let error):
                NSLog("Glaude: listener on \(port) failed: \(error)")
                listener?.cancel()
                if port != 0 { self?.start(port: 0) }  // port taken: fall back to any free port
            default: break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ conn: NWConnection) {
        let http = HTTPConnection(conn)
        let key = ObjectIdentifier(http)
        connections[key] = http
        http.onFinish = { [weak self] in self?.connections[key] = nil }
        http.start { [weak self] request, connection in self?.handle(request, connection) }
    }

    private func handle(_ request: HTTPRequest, _ connection: HTTPConnection) {
        guard request.headers["x-glaude-token"] == token else { return connection.respond(403) }
        let q = request.query

        switch (request.method, request.path) {
        case ("POST", "/event"):
            store.handleEvent(request.json)
            connection.respond(200)

        // A question or permission card. The mod's fetches give up at 30 s, so each poll
        // answers within 25 s: 200 with the answer, 202 "still waiting", 204 "no answer".
        case ("POST", "/wait"):
            guard let key = q["request"], !key.isEmpty else { return connection.respond(404) }
            store.openRequest(key: key, json: request.json)
            pollRequest(key, connection)

        case ("GET", "/wait/next"):
            pollRequest(q["request"] ?? "", connection)

        case ("POST", "/cancel"):
            store.cancelRequest(key: q["request"] ?? "")
            connection.respond(200)

        case ("GET", "/reply/next"):
            let session = q["session"] ?? ""
            store.replyPollArrived(session: session, cwd: q["cwd"] ?? "", pid: Int(q["pid"] ?? "") ?? 0)
            let cancel = store.replyPoll(session: session) { text in
                if let text { connection.respond(200, json: ["text": text]) } else { connection.respond(204) }
            }
            connection.onClose = cancel

        case ("GET", "/state"):
            connection.respond(200, json: store.debugState())

        default:
            connection.respond(404)
        }
    }

    private func pollRequest(_ key: String, _ connection: HTTPConnection) {
        let cancel = store.pollRequest(key: key) { outcome in
            switch outcome {
            case .answered(let answer): connection.respond(200, json: answer)
            case .waiting: connection.respond(202)
            case .gone: connection.respond(204)
            }
        }
        connection.onClose = cancel
    }
}

/// ~/.glaude: the token and port the glaude mod reads to reach the app.
enum GlaudeFiles {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".glaude")

    static func loadOrCreateToken() -> String {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("token")
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let token = (0..<2).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
        write(token, to: url)
        return token
    }

    static func writePort(_ port: UInt16) {
        write(String(port), to: dir.appendingPathComponent("port"))
    }

    private static func write(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
