import Foundation
@_exported import SessionBrokerClient

/// Where the app keeps its OAuth session.
///
/// App code only ever talks to a `SessionStore` value: it never asks where the session
/// lives. Keychain, broker, and in-memory storage are just different values of this type,
/// and ``live(keychainService:broker:environment:)`` is the one place that picks between them.
///
/// Refresh goes through the store too. With the Keychain it simply runs your refresh. With
/// the broker it makes sure only one simulator runs it. Either way, the call site is the same.
public struct SessionStore: Sendable {
    public typealias Refresh = @Sendable (_ refreshToken: String) async throws -> OAuthSession

    /// Which backend this is, for logs and debug screens.
    public let name: String

    private let loadSession: @Sendable () async throws -> OAuthSession?
    private let saveSession: @Sendable (OAuthSession) async throws -> Void
    private let clearSession: @Sendable () async throws -> Void
    private let refreshSession: @Sendable (OAuthSession, @escaping Refresh) async throws -> OAuthSession?

    /// Builds a custom backend. Most apps use ``live(keychainService:broker:environment:)``.
    public init(
        name: String,
        load: @escaping @Sendable () async throws -> OAuthSession?,
        save: @escaping @Sendable (OAuthSession) async throws -> Void,
        clear: @escaping @Sendable () async throws -> Void,
        refresh: @escaping @Sendable (OAuthSession, @escaping Refresh) async throws -> OAuthSession?
    ) {
        self.name = name
        loadSession = load
        saveSession = save
        clearSession = clear
        refreshSession = refresh
    }

    /// The current session, or `nil` when logged out.
    public func session() async throws -> OAuthSession? {
        try await loadSession()
    }

    /// Stores the session returned by login.
    public func save(_ session: OAuthSession) async throws {
        try await saveSession(session)
    }

    /// Logs out. With the broker, every simulator logs out.
    public func clear() async throws {
        try await clearSession()
    }

    /// Replaces an expired session and returns the fresh one, or `nil` when `refresh`
    /// threw ``RefreshTokenRejected`` and the session was cleared.
    public func refresh(_ expired: OAuthSession, using refresh: @escaping Refresh) async throws -> OAuthSession? {
        try await refreshSession(expired, refresh)
    }
}

extension SessionStore {
    /// The Keychain on devices, and the shared broker in simulators.
    ///
    /// Launch a simulator build with the `SESSION_STORE=keychain` environment variable
    /// (Scheme › Run › Arguments) to use the Keychain anyway, for example to debug
    /// Keychain behavior or to run without Docker.
    public static func live(
        keychainService: String,
        broker: @autoclosure () -> SessionBrokerClient = SessionBrokerClient(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SessionStore {
        #if targetEnvironment(simulator)
        if environment["SESSION_STORE"] != "keychain" {
            return .broker(broker())
        }
        #endif
        return .keychain(service: keychainService)
    }

    /// Storage owned by this process alone: whoever notices the expiry refreshes.
    static func local(
        name: String,
        load: @escaping @Sendable () async throws -> OAuthSession?,
        save: @escaping @Sendable (OAuthSession) async throws -> Void,
        clear: @escaping @Sendable () async throws -> Void
    ) -> SessionStore {
        SessionStore(name: name, load: load, save: save, clear: clear) { expired, refresh in
            let refreshed: OAuthSession
            do {
                refreshed = try await refresh(expired.refreshToken)
            } catch is RefreshTokenRejected {
                try await clear()
                return nil
            }
            try await save(refreshed)
            return refreshed
        }
    }
}
