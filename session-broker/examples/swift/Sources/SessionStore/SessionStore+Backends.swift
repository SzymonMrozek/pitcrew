import Foundation

extension SessionStore {
    /// The shared session broker. Use it in simulators only.
    public static func broker(_ client: SessionBrokerClient) -> SessionStore {
        SessionStore(
            name: "Session broker",
            load: { try await client.session() },
            save: { try await client.store($0) },
            clear: { try await client.delete() },
            refresh: { expired, refresh in
                try await BrokeredTokenRefresher(broker: client, refresh: refresh)
                    .refreshedSession(replacing: expired)
            }
        )
    }

    /// One Keychain item, readable after the first unlock and never synced or migrated
    /// to another device.
    public static func keychain(service: String, account: String = "oauth-session") -> SessionStore {
        let item = KeychainItem(service: service, account: account)
        return .local(
            name: "Keychain",
            load: { try item.read().map { try JSONDecoder().decode(OAuthSession.self, from: $0) } },
            save: { try item.write(JSONEncoder().encode($0)) },
            clear: { try item.delete() }
        )
    }

    /// Memory only, for tests and SwiftUI previews.
    public static func inMemory(_ initial: OAuthSession? = nil) -> SessionStore {
        let box = SessionBox(initial)
        return .local(
            name: "In memory",
            load: { await box.value },
            save: { await box.set($0) },
            clear: { await box.set(nil) }
        )
    }
}

private actor SessionBox {
    private(set) var value: OAuthSession?

    init(_ value: OAuthSession?) {
        self.value = value
    }

    func set(_ value: OAuthSession?) {
        self.value = value
    }
}
