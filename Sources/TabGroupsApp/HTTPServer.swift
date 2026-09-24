import TabGroupsCore
import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder().encode(value)) ?? Data())
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(OpenResponse(ok: false, error: message), status: status)
    }
}

/// Tiny HTTP/1.1 server on 127.0.0.1 for the `hbtg` CLI. One request per connection.
final class HTTPServer {
    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(label: "hbtg.http")
    private var listener: NWListener?
    /// Connections whose request has arrived; the idle timeout no longer applies to them
    /// (an explicit open may legitimately wait ~20s for the browser to start).
    private var answered = Set<ObjectIdentifier>()

    /// Invoked on the main queue; call `respond` exactly once.
    var handler: ((HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) -> Void)?

    init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            // Clients that don't send a complete request in time must not hold sockets open.
            let key = ObjectIdentifier(conn)
            self.queue.asyncAfter(deadline: .now() + 15) {
                if self.answered.remove(key) == nil { conn.cancel() }
            }
            self.read(conn, buffer: Data())
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state { NSLog("hbtg http listener failed: \(err)") }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.answered.insert(ObjectIdentifier(conn))
                self.dispatch(request, on: conn)
            } else if isComplete || error != nil || buffer.count > 1_000_000 {
                conn.cancel()
            } else {
                self.read(conn, buffer: buffer)
            }
        }
    }

    /// Returns a request once headers and the full Content-Length body have arrived.
    static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Malformed or negative lengths are treated as an empty body (the request then fails auth/routing).
        let length = max(0, min(Int(headers["content-length"] ?? "0") ?? 0, 1_000_000))
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                           headers: headers, body: Data(body.prefix(length)))
    }

    private func dispatch(_ request: HTTPRequest, on conn: NWConnection) {
        let respond: (HTTPResponse) -> Void = { [weak self] response in
            self?.queue.async { self?.write(response, on: conn) }
        }
        // Reject browser-originated requests outright and require the bearer token.
        guard !token.isEmpty, request.headers["origin"] == nil,
              request.headers["authorization"] == "Bearer \(token)" else {
            respond(.error("unauthorized", status: 401))
            return
        }
        DispatchQueue.main.async {
            guard let handler = self.handler else { return respond(.error("not ready", status: 503)) }
            handler(request, respond)
        }
    }

    private func write(_ response: HTTPResponse, on conn: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                      502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"][response.status] ?? "Status"
        var out = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(response.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
