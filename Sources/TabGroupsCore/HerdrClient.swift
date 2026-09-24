import Foundation

public struct HerdrWorkspace: Codable, Equatable, Sendable {
    public var workspaceId: String
    public var number: Int
    public var label: String
    public var focused: Bool
    public var agentStatus: String?

    public init(workspaceId: String, number: Int, label: String, focused: Bool, agentStatus: String? = nil) {
        self.workspaceId = workspaceId
        self.number = number
        self.label = label
        self.focused = focused
        self.agentStatus = agentStatus
    }

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case number, label, focused
        case agentStatus = "agent_status"
    }
}

public enum HerdrEvent: Equatable, Sendable {
    /// A workspace received UI focus in herdr.
    case focused(workspaceId: String)
    /// Workspace set or naming changed; the caller should re-list workspaces.
    case workspacesChanged
    case other(String)

    /// Parses one newline-delimited event line: `{"event":"workspace_focused","data":{...}}`.
    public static func parse(_ line: Data) -> HerdrEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let name = obj["event"] as? String else { return nil }
        let data = obj["data"] as? [String: Any] ?? [:]
        switch name {
        case "workspace_focused":
            guard let id = data["workspace_id"] as? String else { return nil }
            return .focused(workspaceId: id)
        case "workspace_created", "workspace_closed", "workspace_renamed", "workspace_updated":
            return .workspacesChanged
        default:
            return .other(name)
        }
    }
}

public enum HerdrError: Error, CustomStringConvertible {
    case connect(String)
    case io(String)
    case api(String)

    public var description: String {
        switch self {
        case .connect(let s): return "herdr connect: \(s)"
        case .io(let s): return "herdr io: \(s)"
        case .api(let s): return "herdr api: \(s)"
        }
    }
}

/// Minimal blocking newline-delimited JSON client for herdr's Unix socket.
final class LineSocket {
    private let fd: Int32
    private var buffer = Data()

    init(path: String, timeout: TimeInterval? = nil) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.connect("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { close(fd); throw HerdrError.connect("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw HerdrError.connect("\(path): \(msg)")
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        if let timeout {
            // Bounds reads/writes so a stuck herdr can't block callers forever.
            var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    deinit { close(fd) }

    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { throw HerdrError.io("write failed") }
                offset += n
            }
        }
    }

    /// Returns the next line (without the newline), or nil on EOF.
    func readLine() throws -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return nil }
            if n < 0 { throw HerdrError.io(String(cString: strerror(errno))) }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

public final class HerdrClient: @unchecked Sendable {
    public let socketPath: String
    private let lock = NSLock()
    private var eventSocket: LineSocket?
    private var stopped = false

    public static var defaultSocketPath: String {
        if let env = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"], !env.isEmpty { return env }
        return NSString(string: "~/.config/herdr/herdr.sock").expandingTildeInPath
    }

    public init(socketPath: String = HerdrClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    /// One-shot request on a fresh connection. Returns the `result` object.
    public func request(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let sock = try LineSocket(path: socketPath, timeout: 3)
        let id = "hbtg:\(method):\(UUID().uuidString.prefix(8))"
        try sock.send(["id": id, "method": method, "params": params])
        while let line = try sock.readLine() {
            guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw HerdrError.api(err["message"] as? String ?? "unknown error")
            }
            if obj["id"] as? String == id { return obj["result"] as? [String: Any] ?? [:] }
        }
        throw HerdrError.io("connection closed before response")
    }

    public func listWorkspaces() throws -> [HerdrWorkspace] {
        let result = try request("workspace.list")
        let raw = try JSONSerialization.data(withJSONObject: result["workspaces"] ?? [])
        return try JSONDecoder().decode([HerdrWorkspace].self, from: raw)
    }

    public func focusWorkspace(_ id: String) throws {
        _ = try request("workspace.focus", params: ["workspace_id": id])
    }

    /// Sets display-only tokens on a workspace row (shown via `$name` in herdr's `[ui.sidebar.spaces]` rows).
    /// A nil value clears the token.
    public func reportWorkspaceMetadata(_ id: String, tokens: [String: String?]) throws {
        let values = tokens.mapValues { $0 as Any? ?? NSNull() }
        _ = try request("workspace.report_metadata",
                        params: ["workspace_id": id, "source": "herdr-browser-tab-groups", "tokens": values])
    }

    /// Runs the event subscription on a background thread, reconnecting with backoff.
    /// Note: herdr replays recent events right after subscribing; consumers should
    /// treat focus events as "last one wins" and debounce.
    public func startEvents(
        onConnection: @escaping @Sendable (Bool) -> Void,
        onEvent: @escaping @Sendable (HerdrEvent) -> Void
    ) {
        let thread = Thread { [weak self] in
            var backoff: TimeInterval = 0.5
            while let self, !self.isStopped {
                do {
                    let sock = try LineSocket(path: self.socketPath)
                    self.lock.withLock { self.eventSocket = sock }
                    let types = ["workspace.focused", "workspace.created", "workspace.closed",
                                 "workspace.renamed", "workspace.updated"]
                    try sock.send([
                        "id": "hbtg:subscribe",
                        "method": "events.subscribe",
                        "params": ["subscriptions": types.map { ["type": $0] }],
                    ])
                    guard let ack = try sock.readLine(),
                          let obj = try JSONSerialization.jsonObject(with: ack) as? [String: Any],
                          obj["error"] == nil else {
                        throw HerdrError.api("subscription rejected")
                    }
                    backoff = 0.5
                    onConnection(true)
                    while let line = try sock.readLine() {
                        if let event = HerdrEvent.parse(line) { onEvent(event) }
                    }
                    throw HerdrError.io("event stream closed")
                } catch {
                    self.lock.withLock { self.eventSocket = nil }
                    onConnection(false)
                    if self.isStopped { break }
                    Thread.sleep(forTimeInterval: backoff)
                    backoff = min(backoff * 2, 10)
                }
            }
        }
        thread.name = "herdr-events"
        thread.start()
    }

    public func stop() {
        lock.withLock {
            stopped = true
            eventSocket?.shutdown()
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }
}
