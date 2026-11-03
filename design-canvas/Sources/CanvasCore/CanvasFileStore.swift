import CanvasCore
import Foundation
import Observation

/// Keeps one `.canvas` file in sync with the editor: autosaves shortly after each change,
/// writes atomically, and reloads when something else changes the file, such as a git
/// checkout or an agent editing the JSON.
@MainActor @Observable
public final class CanvasFileStore {
    public enum Status: Equatable {
        case saved
        case saving
        case failed(String)
    }

    public private(set) var url: URL
    public private(set) var status: Status = .saved

    /// Called with the file's new contents after an external change.
    @ObservationIgnored public var onExternalChange: ((CanvasFile) -> Void)?

    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var makeSnapshot: (() -> CanvasFile)?
    /// The bytes last read or written, to tell our own writes from external ones.
    @ObservationIgnored private var knownData: Data?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var isAccessingScope = false

    private static let bookmarkKey = "lastCanvasFile"
    static let saveDelay: Duration = .milliseconds(400)

    public init(url: URL) {
        self.url = url
    }

    public var fileName: String { url.lastPathComponent }

    /// `CANVAS_FILE` wins, then the last file opened, then `Untitled.canvas` in Documents.
    public static func initialURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["CANVAS_FILE"], !path.isEmpty {
            return URL(filePath: (path as NSString).expandingTildeInPath)
        }
        if let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) { return url }
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appending(path: "Untitled.\(CanvasFile.fileExtension)")
    }

    /// Reads the file, or returns nil when it doesn't exist yet. Starts watching it.
    public func load() throws -> CanvasFile? {
        startAccessing()
        defer { watch() }
        guard let loaded = try Self.read(url) else { return nil }
        knownData = loaded.data
        return loaded.file
    }

    private static func read(_ url: URL) throws -> (file: CanvasFile, data: Data)? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: url)
        return (try CanvasFile.decode(data), data)
    }

    /// Saves after a short pause; edits in quick succession write once.
    public func scheduleSave(_ snapshot: @escaping () -> CanvasFile) {
        makeSnapshot = snapshot
        pendingSave?.cancel()
        status = .saving
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes any pending change immediately, for example when the app goes to the background.
    public func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let makeSnapshot else { return }
        do {
            let data = try makeSnapshot().encoded()
            if data != knownData {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                knownData = data
                // An atomic write replaces the file, which ends the old watch.
                watch()
            }
            status = .saved
        } catch {
            status = .failed(error.localizedDescription)
        }
        self.makeSnapshot = nil
    }

    /// Switches to another file. With `contents` the file is written (Save As); without,
    /// it is read (Open) and returned. A file that can't be read leaves the store on the
    /// current one, so later edits don't overwrite it.
    @discardableResult
    public func switchTo(_ newURL: URL, writing contents: CanvasFile? = nil) throws -> CanvasFile? {
        saveNow()
        let isScoped = newURL.startAccessingSecurityScopedResource()
        let loaded: (file: CanvasFile, data: Data)?
        do {
            loaded = contents == nil ? try Self.read(newURL) : nil
        } catch {
            if isScoped { newURL.stopAccessingSecurityScopedResource() }
            throw error
        }
        stopAccessing()
        url = newURL
        isAccessingScope = isScoped
        knownData = loaded?.data
        if let contents {
            makeSnapshot = { contents }
            saveNow()
        }
        watch()
        if let bookmark = try? newURL.bookmarkData() { UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey) }
        return contents ?? loaded?.file
    }

    // MARK: - Watching

    private func watch() {
        watcher?.cancel()
        watcher = nil
        let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fileDidChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func fileDidChange() {
        // Editors and git replace files; give the new one a moment to land, then re-watch.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            self.watch()
            guard let data = try? Data(contentsOf: self.url), data != self.knownData else { return }
            guard let file = try? CanvasFile.decode(data) else {
                self.status = .failed("\(self.fileName) changed on disk and can't be read")
                return
            }
            // The file on disk wins over an edit that hasn't been written yet.
            self.pendingSave?.cancel()
            self.makeSnapshot = nil
            self.knownData = data
            self.status = .saved
            self.onExternalChange?(file)
        }
    }

    // MARK: - Security scope

    // Files picked with the document picker on iOS are only readable inside a scope.
    private func startAccessing() {
        guard !isAccessingScope else { return }
        isAccessingScope = url.startAccessingSecurityScopedResource()
    }

    private func stopAccessing() {
        if isAccessingScope { url.stopAccessingSecurityScopedResource() }
        isAccessingScope = false
    }
}
