import Foundation
import Observation
import SessionStore

@MainActor
@Observable
final class SessionModel {
    private(set) var session: OAuthSession?
    private(set) var deviceID: String?
    private(set) var errorMessage: String?

    private let store: SessionStore
    private let deviceIDs: DeviceIDProvider
    private let authAPI: FakeAuthAPI

    init(store: SessionStore, deviceIDs: DeviceIDProvider, authAPI: FakeAuthAPI) {
        self.store = store
        self.deviceIDs = deviceIDs
        self.authAPI = authAPI
    }

    var backend: String {
        store.name
    }

    func load() async {
        await run {
            session = try await store.session()
            deviceID = try await deviceIDs.deviceID()
        }
    }

    func logIn() async {
        await run {
            let newSession = await authAPI.logIn()
            try await store.save(newSession)
            session = newSession
        }
    }

    func logOut() async {
        await run {
            try await store.clear()
            session = nil
        }
    }

    /// What your API client calls before each request. On a device it refreshes through the
    /// Keychain; in simulators only one of them refreshes and the rest reuse its result.
    func validAccessToken(refreshingWithin margin: TimeInterval = 10) async -> String? {
        var token: String?
        await run {
            guard let current = try await store.session() else {
                session = nil
                return
            }
            guard current.expiresAt.timeIntervalSinceNow <= margin else {
                session = current
                token = current.accessToken
                return
            }
            let authAPI = authAPI
            session = try await store.refresh(current) { try await authAPI.refresh($0) }
            token = session?.accessToken
        }
        return token
    }

    private func run(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
