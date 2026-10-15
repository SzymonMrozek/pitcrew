import Foundation

/// Thrown by your refresh closure when the OAuth server rejected the refresh token
/// (for example `invalid_grant`), so the shared session is no longer usable.
public struct RefreshTokenRejected: Error {
    public init() {}
}

/// Refreshes an expired session so that only one simulator talks to the OAuth server,
/// however many notice the expiry at the same time.
public struct BrokeredTokenRefresher: Sendable {
    public typealias Refresh = @Sendable (_ refreshToken: String) async throws -> OAuthSession

    private let broker: SessionBrokerClient
    private let refresh: Refresh

    /// - Parameter refresh: Calls your OAuth server. Throw ``RefreshTokenRejected`` when the
    ///   refresh token is invalid; any other error is treated as transient.
    public init(broker: SessionBrokerClient, refresh: @escaping Refresh) {
        self.broker = broker
        self.refresh = refresh
    }

    /// Returns a fresh session, or `nil` when the refresh token was rejected and every
    /// simulator is now logged out.
    public func refreshedSession(replacing expired: OAuthSession) async throws -> OAuthSession? {
        guard try await broker.startRefresh(replacing: expired.accessToken) else {
            return try await broker.session()
        }

        let refreshed: OAuthSession
        do {
            refreshed = try await refresh(expired.refreshToken)
        } catch is RefreshTokenRejected {
            try await broker.delete(replacing: expired.accessToken)
            return nil
        }
        // A transient failure propagates and keeps ownership until the broker's timeout,
        // so one flaky request does not log every simulator out.

        try await broker.store(refreshed, replacing: expired.accessToken)
        return refreshed
    }
}
