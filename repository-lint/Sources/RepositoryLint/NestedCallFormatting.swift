import SwiftSyntax

func parentheses(_ syntax: Syntax) -> (TokenSyntax, TokenSyntax, Syntax)? {
    if let call = syntax.as(FunctionCallExprSyntax.self), let left = call.leftParen, let right = call.rightParen {
        return (left, right, Syntax(call.arguments))
    }
    if let call = syntax.as(MacroExpansionExprSyntax.self), let left = call.leftParen, let right = call.rightParen {
        return (left, right, Syntax(call.arguments))
    }
    if let clause = syntax.as(FunctionParameterClauseSyntax.self) {
        return (clause.leftParen, clause.rightParen, Syntax(clause.parameters))
    }
    return nil
}

func nestedCallOpening(_ node: Syntax, locations: SourceLocationConverter) -> TokenSyntax? {
    func line(_ node: some SyntaxProtocol) -> Int {
        locations.location(for: node.positionAfterSkippingLeadingTrivia).line
    }
    guard
        let (opening, _, content) = parentheses(node),
        let first = content.firstToken(viewMode: .sourceAccurate), line(opening) == line(first) else { return nil }
    func multiline(_ syntax: Syntax) -> Bool {
        if let (left, right, _) = parentheses(syntax) { return line(left) != line(right) }
        return syntax.children(viewMode: .sourceAccurate).contains { multiline($0) }
    }
    return content.children(viewMode: .sourceAccurate).contains { multiline($0) } ? opening : nil
}

final class NestedCallVisitor: SyntaxVisitor {
    let locations: SourceLocationConverter
    var breaks: [Int] = []

    init(tree: SourceFileSyntax) {
        locations = SourceLocationConverter(fileName: "Formatting.swift", tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        collect(Syntax(node))
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterClauseSyntax) -> SyntaxVisitorContinueKind {
        collect(Syntax(node))
        return .visitChildren
    }

    func collect(_ node: Syntax) {
        if let opening = nestedCallOpening(node, locations: locations) {
            breaks.append(opening.endPositionBeforeTrailingTrivia.utf8Offset)
        }
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let opening = nestedCallOpening(Syntax(node), locations: locations) {
            breaks.append(opening.endPositionBeforeTrailingTrivia.utf8Offset)
        }
        return .visitChildren
    }
}
