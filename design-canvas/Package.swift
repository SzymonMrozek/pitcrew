// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignCanvas",
    platforms: [.iOS(.v18), .macCatalyst(.v18), .macOS(.v15)],
    products: [
        .library(name: "CanvasCore", targets: ["CanvasCore"]),
        .library(name: "CanvasEngine", targets: ["CanvasEngine"]),
        .library(name: "CanvasRender", targets: ["CanvasRender"]),
        .library(name: "CanvasMCP", targets: ["CanvasMCP"]),
        .executable(name: "canvas-render", targets: ["canvas-render"]),
    ],
    targets: [
        .target(name: "CanvasCore"),
        .target(name: "CanvasEngine", dependencies: ["CanvasCore"]),
        .target(name: "CanvasRender", dependencies: ["CanvasCore", "CanvasEngine"]),
        .target(name: "CanvasMCP", dependencies: ["CanvasCore"]),
        .executableTarget(name: "canvas-render", dependencies: ["CanvasCore", "CanvasEngine"]),
        .testTarget(name: "CanvasCoreTests", dependencies: ["CanvasCore"]),
        .testTarget(name: "CanvasEngineTests", dependencies: ["CanvasEngine", "CanvasCore"]),
        .testTarget(name: "CanvasMCPTests", dependencies: ["CanvasMCP", "CanvasCore"]),
    ]
)
