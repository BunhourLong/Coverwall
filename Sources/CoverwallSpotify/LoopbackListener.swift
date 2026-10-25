import Foundation
import Network

/// The login's redirect target: TCP on 127.0.0.1 only, port picked by the OS (Spotify allows any port for a
/// loopback IP registered without one, SPIKE_NOTES Phase 7.0). Answers one `GET /callback`, then closes.
public final class LoopbackListener: @unchecked Sendable {
    // All mutable state lives on `queue`, where Network.framework calls the handlers.
    private let queue = DispatchQueue(label: "com.bunhourlong.Coverwall.loopback")
    private let listener: NWListener
    private let ready = OneShot<URL>(), received = OneShot<String>()

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [ready, listener] state in
            switch state {
            case .ready: if let port = listener.port { ready.fulfil(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/callback")!)) }
            case .failed(let error), .waiting(let error): ready.fulfil(.failure(error))
            case .cancelled: ready.fulfil(.failure(CancellationError()))
            default: break
            }
        }
        listener.newConnectionHandler = { [queue, received] connection in
            connection.start(queue: queue)
            // shortcut: one read of up to 16 KB; browsers send the request line in the first packet.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let (target, reply) = Self.answer(String(decoding: data ?? Data(), as: UTF8.self))
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let target { received.fulfil(.success(target)) }
            }
        }
        listener.start(queue: queue)
    }

    deinit { listener.cancel() }

    /// `http://127.0.0.1:<port>/callback`, once the listener is up.
    public func redirect() async throws -> URL { try await ready.value(on: queue) }

    /// The callback's request target (`/callback?code=…&state=…`); the listener is closed afterwards either way.
    public func callback(timeout: Duration) async throws -> String {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [received] in received.fulfil(.failure(SpotifyError.loginTimedOut)) }
        defer { listener.cancel() }
        return try await received.value(on: queue)
    }

    /// What to send back for a raw HTTP request, and the request target if it is the callback.
    public static func answer(_ request: String) -> (target: String?, reply: String) {
        let parts = request.prefix { $0 != "\r" && $0 != "\n" }.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].split(separator: "?", maxSplits: 1).first == "/callback" else {
            return (nil, response("404 Not Found", "Not found."))
        }
        return (String(parts[1]), response("200 OK", "Coverwall got Spotify's answer. You can close this tab and return to Terminal."))
    }

    private static func response(_ status: String, _ text: String) -> String {
        let body = "<!doctype html><meta charset=utf-8><title>Coverwall</title><p>\(text)</p>"
        return "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }
}

/// A result delivered once (later ones are ignored) to at most one waiter. Only touched on the listener's queue.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func fulfil(_ outcome: Result<T, Error>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(with: outcome)
        waiter = nil
    }

    func value(on queue: DispatchQueue) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result { continuation.resume(with: result) } else { self.waiter = continuation }
            }
        }
    }
}
