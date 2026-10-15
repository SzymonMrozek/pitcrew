// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RepositoryLint",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "repository-lint", targets: ["SwiftLintCLI"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "601.0.1"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "RepositoryLint",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("Resources/Examples.json")]
        ),
        .executableTarget(name: "SwiftLintCLI", dependencies: ["RepositoryLint", "CSQLite"]),
        .testTarget(name: "RepositoryLintTests", dependencies: ["RepositoryLint"]),
    ]
)
