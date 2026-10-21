// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BuildDistroUpload",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "build-distro-upload", targets: ["build-distro-upload"]),
        .library(name: "BuildDistroUpload", targets: ["BuildDistroUpload"]),
    ],
    targets: [
        .target(name: "BuildDistroUpload"),
        .executableTarget(name: "build-distro-upload", dependencies: ["BuildDistroUpload"]),
        .testTarget(name: "BuildDistroUploadTests", dependencies: ["BuildDistroUpload"]),
    ]
)
