import Foundation
import SessionBrokerClient
import Testing

private let brokerURL = ProcessInfo.processInfo.environment["SESSION_BROKER_URL"].flatMap(URL.init(string:))

private func client(_ clientID: String) -> SessionBrokerClient {
    SessionBrokerClient(baseURL: brokerURL!, clientID: clientID)
}

private func session(_ token: String) -> OAuthSession {
    OAuthSession(
        accessToken: token,
        refreshToken: "refresh-\(token)",
        expiresAt: Date(timeIntervalSince1970: 1_893_456_000)
    )
}

/// Runs against a live broker: `SESSION_BROKER_URL=http://127.0.0.1:8765 swift test`.
@Suite(.serialized, .enabled(if: brokerURL != nil, "Set SESSION_BROKER_URL to a running broker"))
struct SessionBrokerClientTests {
    init() async throws {
        try await client("setup").delete()
    }

    @Test func storesReadsAndDeletesTheSharedSession() async throws {
        let simulatorA = client("simulator-a")
        let simulatorB = client("simulator-b")

        try await simulatorA.store(session("login"))
        let shared = try await simulatorB.session()
        try await simulatorB.delete()

        #expect(shared == session("login"))
        #expect(try await simulatorA.session() == nil)
    }

    @Test func deviceIDIsStableAcrossClients() async throws {
        let first = try await client("simulator-a").deviceID()
        let second = try await client("simulator-b").deviceID()

        #expect(first == second)
        #expect(UUID(uuidString: first) != nil)
    }

    @Test func onlyOneSimulatorRefreshes() async throws {
        try await client("login").store(session("expired"))
        let calls = Counter()
        let refreshers = (0 ..< 5).map { index in
            BrokeredTokenRefresher(broker: client("simulator-\(index)")) { _ in
                await calls.increment()
                try await Task.sleep(for: .milliseconds(100))
                return session("fresh")
            }
        }

        let results = try await withThrowingTaskGroup(of: OAuthSession?.self) { group in
            for refresher in refreshers {
                group.addTask { try await refresher.refreshedSession(replacing: session("expired")) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(await calls.value == 1)
        #expect(results == Array(repeating: session("fresh"), count: 5))
    }

    @Test func rejectedRefreshTokenLogsEverySimulatorOut() async throws {
        try await client("login").store(session("expired"))
        let refresher = BrokeredTokenRefresher(broker: client("simulator-a")) { _ in
            throw RefreshTokenRejected()
        }

        let result = try await refresher.refreshedSession(replacing: session("expired"))

        #expect(result == nil)
        #expect(try await client("simulator-b").session() == nil)
    }

    @Test func staleOwnerCannotOverwriteANewerLogin() async throws {
        let stale = client("stale-owner")
        try await client("login").store(session("old"))
        #expect(try await stale.startRefresh(replacing: "old"))
        try await client("login").store(session("new"))

        await #expect(throws: SessionBrokerError.conflict) {
            try await stale.store(session("stale"), replacing: "old")
        }
        #expect(try await client("reader").session() == session("new"))
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
