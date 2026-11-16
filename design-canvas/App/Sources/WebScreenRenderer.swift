import CanvasCore
import CanvasEngine
import UIKit
import WebKit

/// One render of a web screen: a page at a viewport size in one appearance. Screens that
/// show the same page at the same size share it.
struct WebKey: Hashable {
    let url: String
    let width: Double
    let height: Double
    let dark: Bool

    /// The page a screen shows in an appearance: `lightUrl` for light when it has one.
    init?(screen: Node, dark: Bool) {
        guard screen.isWebScreen else { return nil }
        let base = screen[.url]?.string ?? ""
        let url = dark ? base : (screen[.lightURL]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? base
        guard !url.isEmpty else { return nil }
        let viewport = WebViewport.named(screen[.device]?.string)
        self.url = url
        width = viewport.width
        height = viewport.height
        self.dark = dark
    }
}

/// What a web screen shows: WebKit's picture of the page and its DOM.
struct WebCapture {
    let snapshot: WebSnapshot
    let picture: ImageBox
    let capturedAt: Date

    var png: Data? { UIImage(cgImage: picture.image).pngData() }
}

enum WebRenderError: LocalizedError {
    case noWindow
    case badURL(String)
    case timedOut
    case script(String)

    var errorDescription: String? {
        switch self {
        case .noWindow: "No window to render in"
        case .badURL(let url): "Not a URL: \(url)"
        case .timedOut: "The page didn't finish loading in 20 s"
        case .script(let message): "Capturing the page failed: \(message)"
        }
    }
}

/// Renders web screens with WebKit, offscreen.
///
/// Each capture loads the page in a fresh `WKWebView` the viewport's size, waits for
/// web fonts and a short settle (pages animate in), then takes a bitmap at 2x (or the
/// display's scale, if higher) and the visible DOM. Dark is the page's default look; light sets
/// `data-theme="light"` on the root element and `prefers-color-scheme: light`.
///
/// The web view sits in the editor's window, behind its content: WebKit pauses
/// `requestAnimationFrame` (and so most `<canvas>` drawing) on a page it considers
/// hidden, which a view outside any window is.
@MainActor
final class WebScreenRenderer: NSObject {
    /// How long a page gets to settle after loading, in milliseconds.
    var settle = 1200
    private var container: UIView?

    func capture(_ key: WebKey) async throws -> WebCapture {
        guard let url = URL(string: key.url), url.scheme != nil else { throw WebRenderError.badURL(key.url) }
        let container = try await hostView()
        let size = CGSize(width: key.width, height: key.height)

        let configuration = WKWebViewConfiguration()
        // A fresh store each time, so a reload sees the page's latest code.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.defaultWebpagePreferences.preferredContentMode = key.width < 768 ? .mobile : .desktop
        let web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        web.overrideUserInterfaceStyle = key.dark ? .dark : .light
        web.isUserInteractionEnabled = false
        web.isOpaque = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.showsHorizontalScrollIndicator = false
        container.addSubview(web)
        defer { web.removeFromSuperview() }

        let loader = PageLoader()
        web.navigationDelegate = loader
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20))
        try await loader.wait(seconds: 20)

        do {
            _ = try await web.callAsyncJavaScript(
                WebPageScript.settle, arguments: ["light": !key.dark, "settle": settle], contentWorld: .page
            )
            guard let json = try await web.callAsyncJavaScript(WebPageScript.snapshot, contentWorld: .page) as? String else {
                throw WebRenderError.script("no snapshot")
            }
            let snapshot = try WebSnapshot.decode(Data(json.utf8))
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: size)
            configuration.afterScreenUpdates = true
            // At least 2 pixels per CSS pixel, also on a 1x display.
            let scale = web.window?.screen.scale ?? 2
            if scale < 2 { configuration.snapshotWidth = NSNumber(value: key.width * 2 / scale) }
            let image = try await web.takeSnapshot(configuration: configuration)
            guard let cgImage = image.cgImage else { throw WebRenderError.script("no picture") }
            return WebCapture(snapshot: snapshot, picture: ImageBox(cgImage), capturedAt: .now)
        } catch let error as WebRenderError {
            throw error
        } catch {
            throw WebRenderError.script(error.localizedDescription)
        }
    }

    /// A view behind the editor's content, in its window, that holds the web views.
    private func hostView() async throws -> UIView {
        for _ in 0..<40 {
            if let container, container.window != nil { return container }
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            if let window = windows.first(where: \.isKeyWindow) ?? windows.first {
                let view = UIView(frame: .zero)
                view.isUserInteractionEnabled = false
                view.clipsToBounds = false
                window.insertSubview(view, at: 0)
                container = view
                return view
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw WebRenderError.noWindow
    }
}

/// Waits for one navigation to finish or fail.
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait(seconds: Double) async throws {
        if let result { return try result.get() }
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(seconds))
            self?.finish(.failure(WebRenderError.timedOut))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            if let result {
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
