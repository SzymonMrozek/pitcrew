// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SessionBrokerClient",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SessionBrokerClient", targets: ["SessionBrokerClient"]),
        .library(name: "SessionStore", targets: ["SessionStore"]),
    ],
    targets: [
        .target(name: "SessionBrokerClient"),
        .target(name: "SessionStore", dependencies: ["SessionBrokerClient"]),
        .testTarget(name: "SessionBrokerClientTests", dependencies: ["SessionBrokerClient"]),
        .testTarget(name: "SessionStoreTests", dependencies: ["SessionStore"]),
    ]
)
