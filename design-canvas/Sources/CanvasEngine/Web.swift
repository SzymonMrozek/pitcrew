import CanvasCore
import CoreGraphics

extension LayoutEngine {
    /// A web screen: the page's picture, rendered by WebKit in the editor, with every
    /// captured element's frame. No status bar, no safe areas, square corners. Without a
    /// picture (still loading, failed, or outside the editor) it draws a placeholder
    /// with the page's address and `message`.
    public func webScreen(
        _ root: ResolvedNode, picture: ImageBox?, frames: [String: CGRect] = [:], background: RGBA? = nil,
        message: String? = nil
    ) -> LayoutResult {
        let device = DeviceSpec.of(root)
        let bounds = CGRect(origin: .zero, size: device.size)
        var ops: [DrawOp] = []
        if let picture {
            ops.append(.image(picture, rect: bounds))
        } else {
            let ink = system("secondaryLabel")
            let url = root[.url]?.string ?? "No url"
            let lines = [url, message ?? "Rendered by WebKit in the editor."]
            for (index, line) in lines.enumerated() {
                var spec = TextSpec(
                    string: line, size: index == 0 ? 17 : 13, weight: index == 0 ? 0.3 : 0, color: ink,
                    lineHeight: index == 0 ? 22 : 18, ascender: index == 0 ? 16.2 : 12.4
                )
                spec.alignment = .center
                let y = bounds.midY - 24 + CGFloat(index) * 28
                ops.append(.text(spec, rect: CGRect(x: 24, y: y, width: bounds.width - 48, height: spec.lineHeight)))
            }
        }
        var allFrames = frames
        allFrames[root.id] = bounds
        return LayoutResult(
            size: device.size, background: background ?? system("systemBackground"), cornerRadius: 0, ops: ops,
            frames: allFrames
        )
    }
}
