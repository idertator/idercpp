import Foundation

/// Minimal Debug Adapter Protocol client: runs `lldb-dap` and exchanges
/// `Content-Length`-framed JSON messages with it over pipes.
@MainActor
final class DAPClient {
    typealias JSON = [String: Any]

    var onEvent: ((_ event: String, _ body: JSON) -> Void)?
    var onExit: (() -> Void)?

    private let process = Process()
    private let toAdapter = Pipe()
    private let fromAdapter = Pipe()
    private var seq = 0
    private var pending: [Int: (JSON?) -> Void] = [:]

    func start() throws {
        // Writing to an adapter that already died must not kill the editor.
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["lldb-dap"]
        process.standardInput = toAdapter
        process.standardOutput = fromAdapter
        process.standardError = FileHandle.nullDevice
        try process.run()

        let handle = fromAdapter.fileHandleForReading
        DispatchQueue.global().async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let message = DAPClient.nextMessage(&buffer) {
                    DispatchQueue.main.async { self?.dispatch(message) }
                }
            }
            DispatchQueue.main.async { self?.onExit?() }
        }
    }

    /// Sends a request. `reply` gets the response body, or nil if the request failed.
    func send(_ command: String, _ arguments: JSON = [:], reply: ((JSON?) -> Void)? = nil) {
        seq += 1
        pending[seq] = reply
        let message: JSON = ["seq": seq, "type": "request", "command": command, "arguments": arguments]
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var packet = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        packet.append(body)
        try? toAdapter.fileHandleForWriting.write(contentsOf: packet)
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func dispatch(_ message: JSON) {
        let body = message["body"] as? JSON ?? [:]
        switch message["type"] as? String {
        case "response":
            guard let id = message["request_seq"] as? Int, let reply = pending.removeValue(forKey: id) else { return }
            reply(message["success"] as? Bool == true ? body : nil)
        case "event":
            onEvent?(message["event"] as? String ?? "", body)
        default:
            break
        }
    }

    /// Pops one complete message off the front of `buffer`, if there is one.
    private nonisolated static func nextMessage(_ buffer: inout Data) -> JSON? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        guard let field = header.split(separator: "\r\n").first(where: { $0.hasPrefix("Content-Length:") }),
              let length = Int(field.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces))
        else {
            buffer.removeSubrange(..<headerEnd.upperBound)
            return [:]
        }
        let end = headerEnd.upperBound + length
        guard buffer.count >= end else { return nil }
        let json = try? JSONSerialization.jsonObject(with: buffer[headerEnd.upperBound..<end])
        buffer = Data(buffer[end...])
        return json as? JSON ?? [:]
    }
}
