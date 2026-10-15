import Foundation

/// A stable device ID, swapped the same way as ``SessionStore``: a UUID kept in the
/// Keychain on devices, and the machine-level broker ID in simulators. Every simulator
/// then looks like one device to your backend.
public struct DeviceIDProvider: Sendable {
    private let load: @Sendable () async throws -> String

    public init(load: @escaping @Sendable () async throws -> String) {
        self.load = load
    }

    public func deviceID() async throws -> String {
        try await load()
    }
}

extension DeviceIDProvider {
    /// The Keychain on devices, and the shared broker in simulators.
    /// `SESSION_STORE=keychain` switches simulators to the Keychain, as with ``SessionStore``.
    public static func live(
        keychainService: String,
        broker: @autoclosure () -> SessionBrokerClient = SessionBrokerClient(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DeviceIDProvider {
        #if targetEnvironment(simulator)
        if environment["SESSION_STORE"] != "keychain" {
            return .broker(broker())
        }
        #endif
        return .keychain(service: keychainService)
    }

    public static func broker(_ client: SessionBrokerClient) -> DeviceIDProvider {
        DeviceIDProvider { try await client.deviceID() }
    }

    /// Creates a UUID on first use and keeps it in the Keychain.
    public static func keychain(service: String, account: String = "device-id") -> DeviceIDProvider {
        let item = KeychainItem(service: service, account: account)
        return DeviceIDProvider {
            if let id = try item.read().flatMap({ String(data: $0, encoding: .utf8) }) {
                return id
            }
            let id = UUID().uuidString
            if try item.addIfAbsent(Data(id.utf8)) {
                return id
            }
            // A concurrent first launch stored its ID first; use that one.
            guard let stored = try item.read().flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw KeychainError(status: errSecItemNotFound)
            }
            return stored
        }
    }
}
