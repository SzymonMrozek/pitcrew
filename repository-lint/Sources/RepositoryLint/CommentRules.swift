import SwiftSyntax

extension Inspector {
    struct Comment {
        let text: String
        let first: Int
        let last: Int
        let startsGroup: Bool
        let isDoc: Bool
    }

    static let toolDirectives = ["swiftlint:", "swiftformat:", "sourcery:", "swift-tools-version:"]
    static let reasonedNotes = ["lint:", "Spyable cannot", "Stubable cannot"]
    static let generatorHeaders = ["Generated using", "DO NOT EDIT", "@generated"]

    func checkComments(_ token: TokenSyntax) {
        guard checksComments else { return }
        var leading = comments(in: token.leadingTrivia, from: token.position)
        if token.position.utf8Offset == 0 {
            if isGenerated(leading) {
                checksComments = false
                return
            }
            leading = withoutHeader(leading, trivia: token.leadingTrivia)
        }
        report(leading, continuing: trailingNoteOpen)
        trailingNoteOpen = report(
            comments(in: token.trailingTrivia, from: token.endPositionBeforeTrailingTrivia),
            continuing: false
        )
    }

    func comments(in trivia: Trivia, from start: AbsolutePosition) -> [Comment] {
        var result: [Comment] = []
        var position = start
        var newlines = Int.max
        for piece in trivia {
            let end = position + piece.sourceLength
            switch piece {
            case let .lineComment(text), let .blockComment(text):
                result.append(comment(text, from: position, to: end, newlines: newlines, isDoc: false))
                newlines = 0
            case let .docLineComment(text), let .docBlockComment(text):
                result.append(comment(text, from: position, to: end, newlines: newlines, isDoc: true))
                newlines = 0
            case let .newlines(count), let .carriageReturns(count), let .carriageReturnLineFeeds(count):
                newlines = newlines == Int.max ? count : newlines + count
            case .spaces, .tabs:
                break
            default:
                newlines = Int.max
            }
            position = end
        }
        return result
    }

    func comment(_ text: String, from start: AbsolutePosition, to end: AbsolutePosition, newlines: Int, isDoc: Bool)
        -> Comment {
        Comment(text: commentBody(text), first: line(start), last: line(end), startsGroup: newlines > 1, isDoc: isDoc)
    }

    func isGenerated(_ comments: [Comment]) -> Bool {
        let end = comments.dropFirst().firstIndex(where: { $0.startsGroup }) ?? comments.endIndex
        return comments[..<end].contains { comment in
            !comment.isDoc && Self.generatorHeaders.contains(where: comment.text.hasPrefix)
        }
    }

    func withoutHeader(_ comments: [Comment], trivia: Trivia) -> [Comment] {
        let end = comments.dropFirst().firstIndex(where: { $0.startsGroup }) ?? comments.endIndex
        let blankLineFollows = end < comments.endIndex || trailingNewlines(trivia) > 1
        guard blankLineFollows, !comments[..<end].contains(where: { $0.isDoc }) else { return comments }
        return Array(comments[end...])
    }

    func trailingNewlines(_ trivia: Trivia) -> Int {
        var count = 0
        for piece in trivia.reversed() {
            switch piece {
            case let .newlines(value), let .carriageReturns(value), let .carriageReturnLineFeeds(value):
                count += value
            case .spaces, .tabs:
                continue
            default:
                return count
            }
        }
        return count
    }

    func commentBody(_ text: String) -> String {
        var body = Substring(text)
        for marker in ["///", "//", "/**", "/*"] where body.hasPrefix(marker) {
            body = body.dropFirst(marker.count)
            break
        }
        if body.hasSuffix("*/") { body = body.dropLast(2) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func report(_ comments: [Comment], continuing: Bool) -> Bool {
        var continuesNote = continuing
        var pending: [Comment] = []
        for comment in comments {
            if comment.startsGroup { continuesNote = false }
            let note = isNote(comment.text)
            let allowed = note || continuesNote || Self.toolDirectives.contains(where: comment.text.hasPrefix)
            continuesNote = continuesNote || note
            if allowed || comment.startsGroup {
                flush(&pending)
            }
            if !allowed { pending.append(comment) }
        }
        flush(&pending)
        return continuesNote
    }

    func isNote(_ text: String) -> Bool {
        if text.hasPrefix("lint:allow-comment:") {
            return !text.dropFirst("lint:allow-comment:".count).trimmingCharacters(in: .whitespaces).isEmpty
        }
        return (Self.reasonedNotes + configuration.allowedCommentPrefixes).contains(where: text.hasPrefix)
    }

    func flush(_ pending: inout [Comment]) {
        guard let first = pending.first, let last = pending.last else { return }
        emit(.noComments, first: first.first, affected: Set(first.first ... max(first.first, last.last)))
        pending.removeAll()
    }
}
