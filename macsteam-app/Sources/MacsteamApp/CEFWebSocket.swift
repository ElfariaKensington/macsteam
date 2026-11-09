// Minimal WebSocket client for Steam's CEF debugging port.
// URLSessionWebSocketTask refuses this localhost upgrade on current macOS, so use
// Network.framework and speak the small part of RFC 6455 that CDP needs.
import Foundation
import Network

final class CEFWebSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.macsteam.cef.websocket")
    private var buffer: [UInt8] = []
    private var fragment: [UInt8] = []
    private var handshakeDone = false
    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private var closed = false

    private let host: String
    private let port: UInt16
    private let path: String

    // Called on the socket queue.
    var onText: (@Sendable (String) -> Void)?
    var onClose: (@Sendable (Error?) -> Void)?

    init(host: String, port: UInt16, path: String) {
        self.host = host
        self.port = port
        self.path = path

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port) ?? 8080,
                                  using: params)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.handshakeContinuation = continuation
                self.connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.sendHandshake()
                    case .failed(let error):
                        self.fail(CDPError.disconnected, underlying: error)
                    case .cancelled:
                        self.fail(CDPError.disconnected)
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
                self.receiveLoop()
            }
        }
    }

    func sendText(_ text: String) async throws {
        let payload = Array(text.utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed, self.handshakeDone else {
                    continuation.resume(throwing: CDPError.disconnected)
                    return
                }
                self.sendFrame(opcode: 0x1, payload: payload) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.connection.cancel()
            self.handshakeContinuation?.resume(throwing: CDPError.disconnected)
            self.handshakeContinuation = nil
            self.onClose?(nil)
        }
    }

    // MARK: - Handshake and receive

    private func sendHandshake() {
        var keyBytes = [UInt8](repeating: 0, count: 16)
        for i in keyBytes.indices { keyBytes[i] = UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        let request = "GET \(path) HTTP/1.1\r\n" +
            "Host: \(host):\(port)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(key)\r\n" +
            "Sec-WebSocket-Version: 13\r\n\r\n"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(CDPError.disconnected, underlying: error) }
        })
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail(CDPError.disconnected, underlying: error)
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.parse()
            }
            if isComplete {
                self.fail(CDPError.disconnected)
                return
            }
            if !self.closed {
                self.receiveLoop()
            }
        }
    }

    private func parse() {
        if !handshakeDone {
            guard let end = findHeaderEnd() else { return }
            let header = String(bytes: buffer[0..<end], encoding: .utf8) ?? ""
            buffer.removeFirst(end + 4)
            guard header.hasPrefix("HTTP/1.1 101"),
                  header.lowercased().contains("sec-websocket-accept") else {
                fail(CDPError.badResponse("CEF refused the WebSocket upgrade"))
                return
            }
            handshakeDone = true
            handshakeContinuation?.resume()
            handshakeContinuation = nil
        }

        while buffer.count >= 2 {
            let b0 = buffer[0]
            let b1 = buffer[1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0f
            let masked = (b1 & 0x80) != 0
            var length = Int(b1 & 0x7f)
            var offset = 2

            if length == 126 {
                guard buffer.count >= 4 else { return }
                length = (Int(buffer[2]) << 8) | Int(buffer[3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return }
                var value: UInt64 = 0
                for i in 0..<8 { value = (value << 8) | UInt64(buffer[2 + i]) }
                guard value <= 16 * 1024 * 1024 else {
                    fail(CDPError.badResponse("CEF sent an oversized WebSocket frame"))
                    return
                }
                length = Int(value)
                offset = 10
            }

            let maskOffset = offset
            if masked { offset += 4 }
            guard buffer.count >= offset + length else { return }

            var payload = Array(buffer[offset..<offset + length])
            if masked {
                let mask = Array(buffer[maskOffset..<maskOffset + 4])
                for i in payload.indices { payload[i] ^= mask[i % 4] }
            }
            buffer.removeFirst(offset + length)
            handleFrame(fin: fin, opcode: opcode, payload: payload)
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: [UInt8]) {
        switch opcode {
        case 0x0:
            fragment.append(contentsOf: payload)
            if fin {
                let text = String(bytes: fragment, encoding: .utf8) ?? ""
                fragment.removeAll(keepingCapacity: true)
                if !text.isEmpty { onText?(text) }
            }
        case 0x1:
            if fin {
                if let text = String(bytes: payload, encoding: .utf8), !text.isEmpty {
                    onText?(text)
                }
            } else {
                fragment = payload
            }
        case 0x8:
            close()
        case 0x9:
            sendFrame(opcode: 0xA, payload: payload, completion: nil)
        case 0xA:
            break
        default:
            break
        }
    }

    private func findHeaderEnd() -> Int? {
        guard buffer.count >= 4 else { return nil }
        for i in 0...(buffer.count - 4) where buffer[i] == 13 && buffer[i + 1] == 10 &&
            buffer[i + 2] == 13 && buffer[i + 3] == 10 {
            return i
        }
        return nil
    }

    // MARK: - Send frames

    private func sendFrame(opcode: UInt8, payload: [UInt8],
                           completion: (@Sendable (Error?) -> Void)?) {
        guard !closed else {
            completion?(CDPError.disconnected)
            return
        }
        var frame: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(0x80 | 127)
            let n = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((n >> UInt64(shift)) & 0xFF))
            }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        for i in mask.indices { mask[i] = UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() { frame.append(byte ^ mask[i % 4]) }

        connection.send(content: Data(frame), completion: .contentProcessed { error in
            completion?(error)
        })
    }

    private func fail(_ error: Error, underlying: Error? = nil) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        handshakeContinuation?.resume(throwing: error)
        handshakeContinuation = nil
        onClose?(underlying ?? error)
    }
}
