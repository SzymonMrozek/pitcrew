import SessionStore
import SwiftUI

@main
struct SessionStoreExampleApp: App {
    @State private var model = SessionModel(
        // The only place in the app that knows sessions live in different places on
        // devices and simulators. Everything else just uses `SessionStore`.
        store: .live(keychainService: "dev.pitcrew.SessionStoreExample", broker: .fromEnvironment()),
        deviceIDs: .live(keychainService: "dev.pitcrew.SessionStoreExample", broker: .fromEnvironment()),
        authAPI: FakeAuthAPI()
    )

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}

extension SessionBrokerClient {
    /// Honors `SESSION_BROKER_URL`, so the example can use a broker on another port.
    static func fromEnvironment() -> SessionBrokerClient {
        let url = ProcessInfo.processInfo.environment["SESSION_BROKER_URL"].flatMap(URL.init(string:))
        return SessionBrokerClient(baseURL: url ?? defaultBaseURL)
    }
}
