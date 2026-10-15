import Foundation
import SessionStore
import Testing

/// Hosted by the example app: SwiftPM test bundles have no Keychain entitlement on the
/// iOS Simulator, so the Keychain backend is tested here instead.
struct KeychainSwapTests {
    private let service = "dev.pitcrew.tests.\(UUID().uuidString)"
    /// Nothing listens on this port, so any request to it fails.
    private let unreachableBroker = SessionBrokerClient(baseURL: URL(string: "http://127.0.0.1:9")!)

    private func session(_ token: String) -> OAuthSession {
        OAuthSession(accessToken: token, refreshToken: "refresh-\(token)", expiresAt: Date(timeIntervalSince1970: 1_893_456_000))
    }

    @Test func keychainStoreSavesReadsAndClears() async throws {
        let store = SessionStore.keychain(service: service)
        #expect(try await store.session() == nil)

        try await store.save(session("first"))
        try await store.save(session("second"))
        let reopened = try await SessionStore.keychain(service: service).session()
        try await store.clear()

        #expect(reopened == session("second"))
        #expect(try await store.session() == nil)
    }

    @Test func keychainRefreshRotatesTheStoredSession() async throws {
        let store = SessionStore.keychain(service: service)
        try await store.save(session("expired"))

        let fresh = try await store.refresh(session("expired")) { _ in session("fresh") }

        #expect(fresh == session("fresh"))
        #expect(try await SessionStore.keychain(service: service).session() == session("fresh"))
        try await store.clear()
    }

    @Test func liveStorePicksTheBrokerInSimulators() {
        let live = SessionStore.live(keychainService: service, broker: unreachableBroker, environment: [:])

        #expect(live.name == "Session broker")
    }

    @Test func environmentSwitchesSimulatorsToTheKeychain() async throws {
        let live = SessionStore.live(
            keychainService: service,
            broker: unreachableBroker,
            environment: ["SESSION_STORE": "keychain"]
        )

        try await live.save(session("local"))

        #expect(live.name == "Keychain")
        #expect(try await live.session() == session("local"))
        try await live.clear()
    }

    @Test func keychainDeviceIDIsCreatedOnceAndKept() async throws {
        let service = service
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try await DeviceIDProvider.keychain(service: service).deviceID() }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }

        #expect(ids.count == 1)
        #expect(try await DeviceIDProvider.keychain(service: service).deviceID() == ids.first)
    }
}
