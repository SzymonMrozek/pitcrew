import ProjectDescription

let project = Project(
    name: "SessionStoreExample",
    packages: [.local(path: "../swift")],
    targets: [
        .target(
            name: "SessionStoreExample",
            destinations: .iOS,
            product: .app,
            bundleId: "dev.pitcrew.SessionStoreExample",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .extendingDefault(with: [
                "UILaunchScreen": [:],
                // Lets simulators reach the broker over plain HTTP on 127.0.0.1.
                "NSAppTransportSecurity": ["NSAllowsLocalNetworking": true],
            ]),
            sources: ["Sources/**"],
            dependencies: [.package(product: "SessionStore")]
        ),
        .target(
            name: "SessionStoreExampleTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "dev.pitcrew.SessionStoreExampleTests",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .default,
            sources: ["Tests/**"],
            // Hosted by the app, so the Keychain has the entitlement it needs.
            dependencies: [.target(name: "SessionStoreExample")]
        ),
    ]
)
