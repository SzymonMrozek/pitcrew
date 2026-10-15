import SessionStore
import SwiftUI

struct ContentView: View {
    let model: SessionModel

    var body: some View {
        NavigationStack {
            List {
                Section("Storage") {
                    LabeledContent("Backend", value: model.backend)
                    LabeledContent("Device ID", value: model.deviceID ?? "–")
                }

                Section("Session") {
                    if let session = model.session {
                        LabeledContent("Access token", value: session.accessToken)
                        LabeledContent("Expires", value: session.expiresAt.formatted(date: .omitted, time: .standard))
                    } else {
                        Text("Logged out")
                    }
                }

                Section {
                    Button("Log in") { Task { await model.logIn() } }
                    Button("Refresh now") { Task { await model.validAccessToken(refreshingWithin: .infinity) } }
                    Button("Log out", role: .destructive) { Task { await model.logOut() } }
                }

                if let errorMessage = model.errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                    }
                }
            }
            .navigationTitle("Session store")
            .refreshable { await model.load() }
            .task { await model.load() }
        }
    }
}

#Preview {
    ContentView(model: SessionModel(store: .inMemory(), deviceIDs: DeviceIDProvider { "preview" }, authAPI: FakeAuthAPI()))
}
