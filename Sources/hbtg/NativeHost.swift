import TabGroupsCore
import Foundation

/// Chrome native messaging host. Chrome starts `hbtg chrome-extension://<id>/` when the extension calls
/// `chrome.runtime.connectNative`, and talks to it over stdin/stdout (4-byte little-endian length + JSON).
///
/// The host relays those messages to the app's local WebSocket. When the app isn't running it retries
/// quietly, so Chrome never logs a failed connection. It tells the extension about app availability with
/// `{"type":"app-connected"}` / `{"type":"app-disconnected"}`. stdout carries only framed messages.
enum NativeHost {
    static func run(origin: String) -> Never {
        let relay = Relay(origin: origin)
        relay.start()
        // Chrome closes stdin when the extension disconnects; that ends the host.
        while let message = readMessage() {
            relay.forwardToApp(message)
        }
        exit(0)
    }

    private static func readMessage() -> Data? {
        guard let header = readExactly(4) else { return nil }
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length < 64 * 1024 * 1024 else { return nil }
        return readExactly(Int(length))
    }

    private static func readExactly(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try? FileHandle.standardInput.read(upToCount: count - data.count), !chunk.isEmpty else {
                return nil
            }
            data.append(chunk)
        }
        return data
    }

    private static let writeLock = NSLock()

    static func writeMessage(_ data: Data) {
        writeLock.withLock {
            var length = UInt32(data.count).littleEndian
            let header = Data(bytes: &length, count: 4)
            FileHandle.standardOutput.write(header + data)
        }
    }

    static func writeStatus(_ type: String) {
        writeMessage(Data(#"{"type":"\#(type)"}"#.utf8))
    }

    /// WebSocket client to the app, reconnecting every second while the app is down.
    final class Relay: @unchecked Sendable {
        private let origin: String
        private let queue = DispatchQueue(label: "hbtg.native-host")
        private let session = URLSession(configuration: .ephemeral)
        private var task: URLSessionWebSocketTask?
        private var connected = false

        init(origin: String) {
            self.origin = origin
        }

        func start() {
            queue.async { self.connect() }
        }

        func forwardToApp(_ data: Data) {
            queue.async {
                // Messages while the app is down are dropped; the extension resends its
                // hello/state on "app-connected".
                guard self.connected, let task = self.task, let text = String(data: data, encoding: .utf8) else { return }
                task.send(.string(text)) { _ in }
            }
        }

        private func connect() {
            // Re-read each attempt: the app may have created the config (and token) meanwhile.
            let config = (try? Config.load()) ?? Config()
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(config.bridgePort)")!)
            request.setValue(origin.hasSuffix("/") ? String(origin.dropLast()) : origin, forHTTPHeaderField: "Origin")
            let task = session.webSocketTask(with: request)
            self.task = task
            task.resume()
            // First message authenticates; the app ignores the connection until it arrives.
            let auth = (try? JSONSerialization.data(withJSONObject: ["type": "auth", "token": config.token])) ?? Data()
            task.send(.string(String(decoding: auth, as: UTF8.self))) { _ in }
            receive(on: task)
        }

        private func receive(on task: URLSessionWebSocketTask) {
            task.receive { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard task === self.task else { return }
                    switch result {
                    case .success(let message):
                        if !self.connected {
                            self.connected = true
                            NativeHost.writeStatus("app-connected")
                        }
                        switch message {
                        case .string(let text): NativeHost.writeMessage(Data(text.utf8))
                        case .data(let data): NativeHost.writeMessage(data)
                        @unknown default: break
                        }
                        self.receive(on: task)
                    case .failure:
                        self.disconnected()
                    }
                }
            }
            // A WebSocket only delivers data after the app sends something; ping to learn
            // promptly that the handshake succeeded.
            task.sendPing { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard task === self.task else { return }
                    if error == nil, !self.connected {
                        self.connected = true
                        NativeHost.writeStatus("app-connected")
                    } else if error != nil {
                        self.disconnected()
                    }
                }
            }
        }

        private func disconnected() {
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            if connected {
                connected = false
                NativeHost.writeStatus("app-disconnected")
            }
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.task == nil else { return }
                self.connect()
            }
        }
    }
}
