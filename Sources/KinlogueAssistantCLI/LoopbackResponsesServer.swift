import Darwin
import Foundation
import os

/// A one-purpose stand-in for the provider during the capability check. It listens on
/// 127.0.0.1 only, records the bodies of `POST …/responses`, and answers each with a short
/// streamed message so the CLI completes its turn. Nothing leaves the machine.
public final class LoopbackResponsesServer: Sendable {
    public static let maximumBodyBytes = 1_024 * 1_024
    static let maximumHeaderBytes = 64 * 1_024

    public let answer: String
    public let port: UInt16
    private let socket: Int32
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var bodies: [Data] = []
        var stopped = false
        var finished = false
    }

    public init(answer: String) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LoopbackServerError.unavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && listen(descriptor, 4) == 0
                    && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else {
            close(descriptor)
            throw LoopbackServerError.unavailable
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        self.answer = answer
        self.port = UInt16(bigEndian: address.sin_port)
        self.socket = descriptor
        // The thread holds the socket and the state, not the server, so dropping the server stops it.
        Thread.detachNewThread { [socket = descriptor, state, answer] in
            Self.serve(socket: socket, state: state, answer: answer)
        }
    }

    deinit {
        stop()
    }

    public var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    public var bodies: [Data] { state.withLock { $0.bodies } }

    /// Stops accepting and waits briefly for the accept loop to leave.
    public func stop() {
        let alreadyStopped = state.withLock { state -> Bool in
            defer { state.stopped = true }
            return state.stopped
        }
        guard !alreadyStopped else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !state.withLock({ $0.finished }), ProcessInfo.processInfo.systemUptime < deadline {
            usleep(5_000)
        }
        close(socket)
    }

    private static func serve(socket: Int32, state: OSAllocatedUnfairLock<State>, answer: String) {
        defer { state.withLock { $0.finished = true } }
        while !state.withLock({ $0.stopped }) {
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            let connection = accept(socket, nil, nil)
            guard connection >= 0 else { continue }
            handle(connection, state: state, answer: answer)
            close(connection)
        }
    }

    private static func handle(_ connection: Int32, state: OSAllocatedUnfairLock<State>, answer: String) {
        _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, [Int32(1)], socklen_t(MemoryLayout<Int32>.size))

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0, received.count + count <= Self.maximumHeaderBytes + Self.maximumBodyBytes else { return }
            received.append(contentsOf: buffer[0..<count])
            headerEnd = received.range(of: separator)
            if headerEnd == nil, received.count > Self.maximumHeaderBytes { return }
        }
        guard let headerEnd else { return }
        let header = String(decoding: received[received.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let length = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first

        guard requestLine.count >= 2, requestLine[0] == "POST", requestLine[1].hasSuffix("/responses"),
              let length, (0...Self.maximumBodyBytes).contains(length) else {
            send(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        var body = Data(received[headerEnd.upperBound...])
        while body.count < length {
            let count = recv(connection, &buffer, min(buffer.count, length - body.count), 0)
            guard count > 0 else { return }
            body.append(contentsOf: buffer[0..<count])
        }
        let complete = Data(body.prefix(length))
        state.withLock { $0.bodies.append(complete) }
        send(connection, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n" + events(answer: answer))
    }

    private static func events(answer: String) -> String {
        let item: [String: Any] = [
            "type": "message", "id": "kl_check_message", "role": "assistant", "status": "completed",
            "content": [["type": "output_text", "text": answer, "annotations": [Any]()]],
        ]
        let response: [String: Any] = [
            "id": "kl_check_response", "object": "response", "status": "completed", "output": [item],
            "usage": ["input_tokens": 1, "output_tokens": 1, "total_tokens": 2],
        ]
        var inProgress = response
        inProgress["status"] = "in_progress"
        inProgress["output"] = [Any]()
        let sequence: [[String: Any]] = [
            ["type": "response.created", "response": inProgress],
            ["type": "response.output_item.added", "output_index": 0, "item": item],
            ["type": "response.output_item.done", "output_index": 0, "item": item],
            ["type": "response.completed", "response": response],
        ]
        return sequence.map { event in
            let data = (try? JSONSerialization.data(withJSONObject: event)) ?? Data("{}".utf8)
            return "event: \(event["type"] as! String)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
        }.joined()
    }

    private static func send(_ connection: Int32, _ text: String) {
        let data = Data(text.utf8)
        var offset = 0
        data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let sent = Darwin.send(connection, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }
}

public enum LoopbackServerError: Error, Equatable, Sendable {
    case unavailable
}
