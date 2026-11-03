import Foundation

/// Where a comment thread is pinned.
public struct CommentAnchor: Hashable, Codable, Sendable {
    /// A pin on a rendered node. The pin follows the node when layout changes.
    public struct NodeAnchor: Hashable, Codable, Sendable {
        /// The canvas item the node was rendered in, such as `settings#light`.
        public var item: String
        /// The resolved node ID, instance paths included.
        public var node: String
        /// Offset from the node's top-left corner, in screen points.
        public var dx: Double
        public var dy: Double

        public init(item: String, node: String, dx: Double, dy: Double) {
            self.item = item
            self.node = node
            self.dx = dx
            self.dy = dy
        }
    }

    /// Page coordinates, for a pin anywhere on the canvas. For a node pin, the last
    /// known position, used when the node is no longer rendered.
    public var x: Double
    public var y: Double
    public var node: NodeAnchor?
    /// The page a pin without a node sits on; nil for the first page.
    public var page: String?

    public init(x: Double, y: Double, node: NodeAnchor? = nil, page: String? = nil) {
        self.x = x
        self.y = y
        self.node = node
        self.page = page
    }
}

public struct Comment: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var author: String
    public var body: String
    public var createdAt: Date
}

public struct CommentThread: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var anchor: CommentAnchor
    public var comments: [Comment]
    public var isResolved: Bool

    public var title: String { comments.first?.body ?? "" }
}

public enum CommentError: Error, Equatable {
    case unknownThread(String)
    case emptyBody
}

/// Comment threads, kept apart from the document: comments never conflict with design
/// edits, never enter undo history, and sync as their own stream.
public struct CommentStore: Hashable, Codable, Sendable {
    public private(set) var threads: [String: CommentThread] = [:]

    public init() {}

    /// Threads oldest first, which is also their pin number.
    public var ordered: [CommentThread] {
        threads.values.sorted { ($0.comments.first?.createdAt ?? .distantPast, $0.id) < ($1.comments.first?.createdAt ?? .distantPast, $1.id) }
    }

    public func number(of id: String) -> Int? {
        ordered.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    @discardableResult
    public mutating func start(at anchor: CommentAnchor, author: String, body: String, now: Date = Date()) throws -> CommentThread {
        let body = try Self.validated(body)
        let thread = CommentThread(
            id: Self.newID(),
            anchor: anchor,
            comments: [Comment(id: Self.newID(), author: author, body: body, createdAt: now)],
            isResolved: false
        )
        threads[thread.id] = thread
        return thread
    }

    @discardableResult
    public mutating func reply(to id: String, author: String, body: String, now: Date = Date()) throws -> Comment {
        guard threads[id] != nil else { throw CommentError.unknownThread(id) }
        let comment = Comment(id: Self.newID(), author: author, body: try Self.validated(body), createdAt: now)
        threads[id]?.comments.append(comment)
        return comment
    }

    public mutating func setResolved(_ id: String, _ isResolved: Bool) throws {
        guard threads[id] != nil else { throw CommentError.unknownThread(id) }
        threads[id]?.isResolved = isResolved
    }

    public mutating func move(_ id: String, to anchor: CommentAnchor) throws {
        guard threads[id] != nil else { throw CommentError.unknownThread(id) }
        threads[id]?.anchor = anchor
    }

    public mutating func delete(_ id: String) throws {
        guard threads.removeValue(forKey: id) != nil else { throw CommentError.unknownThread(id) }
    }

    private static func validated(_ body: String) throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CommentError.emptyBody }
        return trimmed
    }

    private static func newID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
}
