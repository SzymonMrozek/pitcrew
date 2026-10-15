import Foundation
import SessionStore
import Testing

func session(_ token: String) -> OAuthSession {
    OAuthSession(
        accessToken: token,
        refreshToken: "refresh-\(token)",
        expiresAt: Date(timeIntervalSince1970: 1_893_456_000)
    )
}

struct TransientError: Error {}

/// The refresh contract every backend shares, checked on the in-memory store.
struct LocalRefreshTests {
    @Test func successfulRefreshIsSaved() async throws {
        let store = SessionStore.inMemory(session("expired"))

        let fresh = try await store.refresh(session("expired")) { refreshToken in
            #expect(refreshToken == "refresh-expired")
            return session("fresh")
        }

        #expect(fresh == session("fresh"))
        #expect(try await store.session() == session("fresh"))
    }

    @Test func rejectedRefreshTokenLogsOut() async throws {
        let store = SessionStore.inMemory(session("expired"))

        let fresh = try await store.refresh(session("expired")) { _ in throw RefreshTokenRejected() }

        #expect(fresh == nil)
        #expect(try await store.session() == nil)
    }

    @Test func transientFailureKeepsTheSession() async throws {
        let store = SessionStore.inMemory(session("expired"))

        await #expect(throws: TransientError.self) {
            try await store.refresh(session("expired")) { _ in throw TransientError() }
        }
        #expect(try await store.session() == session("expired"))
    }
}

private let brokerURL = ProcessInfo.processInfo.environment["SESSION_BROKER_URL"].flatMap(URL.init(string:))

/// Runs against a live broker. On the iOS Simulator, pass the URL as `TEST_RUNNER_SESSION_BROKER_URL`.
@Suite(.serialized, .enabled(if: brokerURL != nil, "Set SESSION_BROKER_URL to a running broker"))
struct BrokerBackedStoreTests {
    private func broker(_ clientID: String) -> SessionBrokerClient {
        SessionBrokerClient(baseURL: brokerURL!, clientID: clientID)
    }

    init() async throws {
        try await broker("setup").delete()
    }

    @Test func aRefreshInOneSimulatorIsSeenByAnother() async throws {
        let simulatorA = SessionStore.broker(broker("simulator-a"))
        let simulatorB = SessionStore.broker(broker("simulator-b"))
        try await simulatorA.save(session("expired"))

        _ = try await simulatorA.refresh(session("expired")) { _ in session("fresh") }

        #expect(try await simulatorB.session() == session("fresh"))
    }

    #if targetEnvironment(simulator)
    @Test func liveStoreUsesTheBrokerInSimulators() async throws {
        let service = "pitcrew.tests.\(UUID().uuidString)"
        try await broker("other-simulator").store(session("shared"))

        let live = SessionStore.live(keychainService: service, broker: broker("this-simulator"), environment: [:])

        #expect(live.name == "Session broker")
        #expect(try await live.session() == session("shared"))
    }

    @Test func liveDeviceIDComesFromTheBroker() async throws {
        let live = DeviceIDProvider.live(
            keychainService: "pitcrew.tests.\(UUID().uuidString)",
            broker: broker("a"),
            environment: [:]
        )

        #expect(try await live.deviceID() == broker("b").deviceID())
    }
    #endif
}
