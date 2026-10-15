import Foundation
import SessionStore

/// Stands in for your OAuth server: issues short-lived tokens and rotates refresh tokens.
actor FakeAuthAPI {
    private var revokedRefreshTokens: Set<String> = []

    func logIn() -> OAuthSession {
        issue()
    }

    func refresh(_ refreshToken: String) throws -> OAuthSession {
        guard !revokedRefreshTokens.contains(refreshToken) else {
            throw RefreshTokenRejected()
        }
        revokedRefreshTokens.insert(refreshToken)
        return issue()
    }

    private func issue() -> OAuthSession {
        let id = UUID().uuidString.prefix(8).lowercased()
        return OAuthSession(
            accessToken: "access-\(id)",
            refreshToken: "refresh-\(id)",
            expiresAt: .now.addingTimeInterval(60)
        )
    }
}
