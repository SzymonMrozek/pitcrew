import Foundation

/// The OAuth session the broker shares between simulators.
public struct OAuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public enum SessionBrokerError: Error, Equatable {
    /// A conditional update or delete lost its refresh ownership to another process.
    case conflict
    case unexpectedStatus(Int)
}

/// A dependency-free client for the simulator session broker HTTP API.
public struct SessionBrokerClient: Sendable {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8765")!

    private let baseURL: URL
    private let clientIDHeader: String
    private let clientID: String
    private let urlSession: URLSession

    /// - Parameters:
    ///   - clientIDHeader: Must match the broker's `SESSION_BROKER_CLIENT_ID_HEADER`.
    ///   - clientID: Identifies this app process. Keep one per launch.
    public init(
        baseURL: URL = defaultBaseURL,
        clientIDHeader: String = "X-Session-Client-ID",
        clientID: String = UUID().uuidString,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.clientIDHeader = clientIDHeader
        self.clientID = clientID
        self.urlSession = urlSession
    }

    /// A stable ID for the development machine, shared by every simulator.
    public func deviceID() async throws -> String {
        let response: DeviceIDResponse = try await send("GET", "device-id")
        return response.deviceId
    }

    /// The shared session, or `nil` when nobody is logged in. Waits while another process refreshes.
    public func session() async throws -> OAuthSession? {
        do {
            return try await send("GET", "session") as OAuthSession
        } catch SessionBrokerError.unexpectedStatus(404) {
            return nil
        }
    }

    /// Returns `true` when this process must perform the OAuth refresh, and `false` when
    /// another process already refreshed and ``session()`` holds the new tokens.
    public func startRefresh(replacing accessToken: String) async throws -> Bool {
        let response: StartRefreshResponse = try await send(
            "POST",
            "refresh/start",
            body: StartRefreshRequest(replacingAccessToken: accessToken)
        )
        return response.shouldRefresh
    }

    /// Stores a session. Pass `replacing` only to complete a refresh this process owns.
    public func store(_ session: OAuthSession, replacing accessToken: String? = nil) async throws {
        try await sendWithoutResponse(
            "PUT",
            "session",
            body: UpdateSessionRequest(session: session, replacingAccessToken: accessToken)
        )
    }

    /// Logs out every simulator. Pass `replacing` only to abandon a refresh this process owns.
    public func delete(replacing accessToken: String? = nil) async throws {
        try await sendWithoutResponse(
            "DELETE",
            "session",
            body: DeleteSessionRequest(replacingAccessToken: accessToken)
        )
    }

    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: (some Encodable)? = String?.none
    ) async throws -> Response {
        let data = try await sendWithoutResponse(method, path, body: body)
        return try Self.decoder.decode(Response.self, from: data)
    }

    @discardableResult
    private func sendWithoutResponse(
        _ method: String,
        _ path: String,
        body: (some Encodable)? = String?.none
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(clientID, forHTTPHeaderField: clientIDHeader)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200 ..< 300:
            return data
        case 409:
            throw SessionBrokerError.conflict
        default:
            throw SessionBrokerError.unexpectedStatus(status)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // The broker emits fractional seconds only when they are non-zero.
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(string, strategy: .iso8601) {
                return date
            }
            return try Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        return decoder
    }()
}

private struct DeviceIDResponse: Decodable {
    let deviceId: String
}

private struct StartRefreshRequest: Encodable {
    let replacingAccessToken: String
}

private struct StartRefreshResponse: Decodable {
    let shouldRefresh: Bool
}

private struct UpdateSessionRequest: Encodable {
    let session: OAuthSession
    let replacingAccessToken: String?
}

private struct DeleteSessionRequest: Encodable {
    let replacingAccessToken: String?
}
