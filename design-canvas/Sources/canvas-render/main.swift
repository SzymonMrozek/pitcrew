import CanvasCore
import CanvasEngine
import Foundation

// Renders every screen (light and dark), component and token board of a .canvas file to PNGs,
// without the editor: `canvas-render [file.canvas] [output-dir] [scale]`.
// `canvas-render --sample file.canvas` writes the sample document instead, to start from.
let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "--sample", let path = arguments.dropFirst().first {
    try CanvasFile(document: .sample()).encoded().write(to: URL(filePath: path))
    exit(0)
}
let input = arguments.first.flatMap { $0.hasSuffix(".canvas") ? $0 : nil }
let rest = input == nil ? Array(arguments) : Array(arguments.dropFirst())
let output = URL(filePath: rest.first ?? ".")
let scale = rest.dropFirst().first.flatMap(Double.init).map { CGFloat($0) } ?? 3

let document: CanvasDocument
if let input {
    document = try CanvasFile.decode(Data(contentsOf: URL(filePath: input))).document
} else {
    document = .sample()
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for node in document.canvasItems {
    switch node.kind {
    case .screen:
        let tree = try document.resolve(node.id)
        for appearance in Appearance.allCases {
            let layout = LayoutEngine(tokens: document.tokens, appearance: appearance)
                .screen(tree, device: DeviceSpec.named(node[.device]?.string))
            let url = output.appending(path: "\(node.id)-\(appearance.rawValue).png")
            try Rasterizer.png(layout, scale: scale)?.write(to: url)
            print(url.path(percentEncoded: false))
        }
    case .component:
        guard let root = document.children(of: node.id).first else { continue }
        let layout = LayoutEngine(tokens: document.tokens, appearance: .light).component(try document.resolve(root.id))
        let url = output.appending(path: "\(node.id).png")
        try Rasterizer.png(layout, scale: scale)?.write(to: url)
        print(url.path(percentEncoded: false))
    default:
        continue
    }
}

for board in document.tokens.boards() {
    let layout = LayoutEngine(tokens: document.tokens, appearance: .light).component(board.root)
    let url = output.appending(path: "tokens.\(board.id).png")
    try Rasterizer.png(layout, scale: scale)?.write(to: url)
    print(url.path(percentEncoded: false))
}
