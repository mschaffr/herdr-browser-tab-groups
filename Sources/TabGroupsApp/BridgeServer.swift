import TabGroupsCore
import Foundation
import Network

/// WebSocket server on 127.0.0.1 for the Chrome extension, reached through the `hbtg` native messaging host.
///
/// Authentication happens in-band: a connection receives nothing and is not counted until its first
/// message is `{"type":"auth","token":…}` with the config token (the host reads it from the 0600 config
/// file). Unauthenticated connections are dropped after 5 seconds. Handshake-level rejection is not
/// enough: Network.framework answers 400 but still hands the connection over as ready.
final class BridgeServer {
    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(label: "hbtg.bridge")
    private var listener: NWListener?
    /// Authenticated connections; only these receive messages and count as "extension connected".
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Called on the main queue.
    var onMessage: ((ExtensionToApp) -> Void)?
    var onConnectionCountChange: ((Int) -> Void)?

    init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    func start() throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state { NSLog("hbtg bridge listener failed: \(err)") }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    var connectionCount: Int { queue.sync { connections.count } }

    func send(_ message: AppToExtension) {
        let data = message.jsonData()
        queue.async {
            for conn in self.connections.values { self.sendText(data, on: conn) }
        }
    }

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive(on: conn)
                self.queue.asyncAfter(deadline: .now() + 5) {
                    if self.connections[key] == nil { conn.cancel() }
                }
            case .failed, .cancelled:
                if self.connections.removeValue(forKey: key) != nil { self.notifyCount() }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                // Peer went away (reset / EOF): normal when Chrome or the service worker restarts.
                conn.cancel()
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close {
                conn.cancel()
                return
            }
            guard meta?.opcode == .text, let content else {
                self.receive(on: conn)
                return
            }
            let key = ObjectIdentifier(conn)
            if self.connections[key] == nil {
                // First message must authenticate; anything else closes the connection.
                guard self.isValidAuth(content) else {
                    conn.cancel()
                    return
                }
                self.connections[key] = conn
                self.notifyCount()
            } else if let msg = ExtensionToApp.parse(content) {
                DispatchQueue.main.async { self.onMessage?(msg) }
            }
            self.receive(on: conn)
        }
    }

    private func isValidAuth(_ data: Data) -> Bool {
        guard !token.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "auth", let given = obj["token"] as? String,
              given.utf8.count == token.utf8.count else { return false }
        // Constant-time comparison.
        return zip(given.utf8, token.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func sendText(_ data: Data, on conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func notifyCount() {
        let count = connections.count
        DispatchQueue.main.async { self.onConnectionCountChange?(count) }
    }
}
