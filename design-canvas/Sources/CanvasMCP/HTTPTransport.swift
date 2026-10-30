import Foundation
import Network

/// Streamable HTTP for MCP, reduced to what a local editor needs: `POST /mcp` with one
/// JSON-RPC message, answered with one JSON body. No SSE stream, since the server never
/// sends requests of its own. Listens on loopback only and rejects foreign origins,
/// which is the DNS-rebinding protection the MCP spec asks local servers for.
public final class HTTPTransport: Sendable {
    public typealias Handler = @Sendable (Data) async -> Data?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "design-canvas.mcp")
    private let handler: Handler

    public init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    public func start(onState: @escaping @Sendable (NWListener.State) -> Void = { _ in }) {
        listener.stateUpdateHandler = onState
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }

    /// The bound port, once the listener is ready. Useful when started on port 0.
    public var port: UInt16? { listener.port?.rawValue }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                Task { await self.respond(to: request, on: connection) }
            case .incomplete where error == nil && !isComplete:
                self.receive(on: connection, buffer: buffer)
            default:
                self.send(HTTPResponse(status: 400, body: Data()), on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        if let origin = request.headers["origin"], !HTTPTransport.isLocal(origin: origin) {
            return send(HTTPResponse(status: 403, body: Data("Forbidden origin".utf8)), on: connection)
        }
        guard request.path.split(separator: "?").first == "/mcp" else {
            return send(HTTPResponse(status: 404, body: Data()), on: connection)
        }
        switch request.method {
        case "POST":
            if let body = await handler(request.body) {
                send(HTTPResponse(status: 200, contentType: "application/json", body: body), on: connection)
            } else {
                send(HTTPResponse(status: 202, body: Data()), on: connection)
            }
        case "GET":
            // No server-initiated stream.
            send(HTTPResponse(status: 405, body: Data()), on: connection)
        case "DELETE":
            send(HTTPResponse(status: 200, body: Data()), on: connection)
        default:
            send(HTTPResponse(status: 405, body: Data()), on: connection)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func isLocal(origin: String) -> Bool {
        guard let host = URL(string: origin)?.host else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

struct HTTPRequest: Equatable {
    enum Parse: Equatable {
        case complete(HTTPRequest)
        case incomplete
        case invalid
    }

    let method: String
    let path: String
    /// Lowercased names.
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .complete(HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(body.prefix(length))
        ))
    }
}

struct HTTPResponse {
    let status: Int
    var contentType: String? = nil
    let body: Data

    var serialized: Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}
