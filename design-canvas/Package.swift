// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignCanvas",
    platforms: [.iOS(.v18), .macCatalyst(.v18), .macOS(.v15)],
    products: [
        .library(name: "CanvasCore", targets: ["CanvasCore"]),
        .library(name: "CanvasRender", targets: ["CanvasRender"]),
        .library(name: "CanvasMCP", targets: ["CanvasMCP"]),
    ],
    targets: [
        .target(name: "CanvasCore"),
        .target(name: "CanvasRender", dependencies: ["CanvasCore"]),
        .target(name: "CanvasMCP", dependencies: ["CanvasCore"]),
        .testTarget(name: "CanvasCoreTests", dependencies: ["CanvasCore"]),
        .testTarget(name: "CanvasMCPTests", dependencies: ["CanvasMCP", "CanvasCore"]),
    ]
)
