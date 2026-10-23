import Foundation
import SwiftParser
import SwiftSyntax

public struct Finding: Codable, Equatable, Sendable {
    public let rule: Rule
    public let line: Int
    public var affected: Set<Int>
}

public struct Inspection: Sendable {
    public let findings: [Finding]
    public let breaks: [Int]
    public let parseNS: UInt64
    public let walkNS: UInt64
}

public func inspect(path: String, source: String, configuration: LintConfiguration = .init()) -> Inspection {
    let start = DispatchTime.now().uptimeNanoseconds
    let tree = Parser.parse(source: source)
    let parsed = DispatchTime.now().uptimeNanoseconds
    let visitor = Inspector(path: path, source: source, tree: tree, configuration: configuration)
    visitor.walk(tree)
    visitor.finish()
    return Inspection(
        findings: visitor.findings.sorted {
            ($0.rule.rawValue, $0.line) < ($1.rule.rawValue, $1.line)
        },
        breaks: visitor.breaks.sorted(),
        parseNS: parsed - start,
        walkNS: DispatchTime.now().uptimeNanoseconds - parsed
    )
}

public func formatNestedCalls(_ source: String) -> String {
    let tree = Parser.parse(source: source)
    let visitor = NestedCallVisitor(tree: tree)
    visitor.walk(tree)
    var bytes = Array(source.utf8)
    for offset in visitor.breaks.sorted().reversed() {
        bytes.insert(10, at: offset)
    }
    return String(bytes: bytes, encoding: .utf8)!
}

final class Inspector: SyntaxVisitor {
    let path: String
    let configuration: LintConfiguration
    let source: String
    let rows: [String]
    let locations: SourceLocationConverter
    let designTokens: Bool
    let currency: Bool
    let number: Bool
    let percentage: Bool
    let needsReferences: Bool
    let customColorEnabled: Bool
    let hasForEach: Bool
    let testStem: String?
    var findings: [Finding] = []
    var breaks: [Int] = []
    var helpers: Set<String> = []
    var rowCalls: [(String, Int)] = []
    var contexts: [(String, Int)] = []
    var constructors: Set<String> = []
    var directSetup: [Int] = []
    var firstTest: Int?
    var dependencies: [(VariableDeclSyntax, String, String)] = []
    var bindables: [(VariableDeclSyntax, String, SyntaxIdentifier)] = []
    var references: [String: [Reference]] = [:]

    struct Reference {
        let line: Int
        let owner: SyntaxIdentifier?
        let type: String?
        let view: SyntaxIdentifier?
        let movable: Bool
    }

    init(path: String, source: String, tree: SourceFileSyntax, configuration: LintConfiguration) {
        self.configuration = configuration
        self.path = path
        self.source = source
        rows = source.components(separatedBy: "\n")
        locations = SourceLocationConverter(fileName: path, tree: tree)
        designTokens = usesDesignTokens(path, configuration: configuration)
        currency = path.hasSuffix(".swift") && path.hasPrefix("Modules/") && !path.contains("Generated/")
            && !path.hasPrefix("Modules/Utilities/CurrencyFormatting/")
        number = path.hasSuffix(".swift") && path.hasPrefix("Modules/") && !path.contains("Generated/")
            && !path.hasPrefix("Modules/Utilities/NumberFormatting/")
        percentage = path.hasSuffix(".swift") && path.hasPrefix("Modules/") && !path.contains("Generated/")
            && !path.hasPrefix("Modules/Utilities/PercentageFormatting/")
        needsReferences = source.contains("@Dependency") || source.contains("@Bindable")
        hasForEach = source.contains("ForEach")
        let stem = URL(fileURLWithPath: path).lastPathComponent.replacingOccurrences(of: ".tests.swift", with: "")
        testStem = path
            .hasSuffix(".tests.swift") && (stem.hasSuffix("Interactor") || stem.hasSuffix("ViewModel")) ? stem : nil
        customColorEnabled = usesDesignTokens(path, configuration: configuration)
            && path != "Modules/Extensions/SwiftExtensions/Sources/Color+Hex.swift"
            && !rows.prefix(20).contains { row in
                guard let range = row.range(of: "lint:allow-custom-color-file:") else { return false }
                return !row[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        super.init(viewMode: .sourceAccurate)
    }

    func line(_ position: AbsolutePosition) -> Int {
        locations.location(for: position).line
    }

    func line(_ node: some SyntaxProtocol) -> Int {
        line(node.positionAfterSkippingLeadingTrivia)
    }

    func nearby(_ marker: String, line: Int, above: Int = 3, reason: Bool = false) -> Bool {
        rows[max(0, line - above - 1) ..< min(rows.count, line)].contains { row in
            guard let range = row.range(of: marker) else { return false }
            return !reason || !row[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func header(_ marker: String) -> Bool {
        rows.prefix(20).contains { row in
            guard let range = row.range(of: marker) else { return false }
            return !row[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func emit(
        _ rule: Rule,
        _ node: some SyntaxProtocol,
        through end: AbsolutePosition? = nil,
        exception: String? = nil,
        merge: Bool = false,
        affected: Set<Int>? = nil
    ) {
        let first = line(node)
        emit(
            rule,
            first: first,
            affected: affected ?? Set(first ... max(first, line(end ?? node.positionAfterSkippingLeadingTrivia))),
            exception: exception,
            merge: merge
        )
    }

    func emit(_ rule: Rule, first: Int, affected: Set<Int>, exception: String? = nil, merge: Bool = false) {
        if let exception, nearby(exception, line: first) { return }
        var finding = Finding(rule: rule, line: first, affected: affected)
        if merge {
            let overlaps = findings.filter { $0.rule == rule && !$0.affected.isDisjoint(with: affected) }
            for previous in overlaps {
                finding = Finding(
                    rule: rule,
                    line: min(finding.line, previous.line),
                    affected: finding.affected.union(previous.affected)
                )
            }
            findings.removeAll { $0.rule == rule && !$0.affected.isDisjoint(with: finding.affected) }
        }
        findings.append(finding)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        checkCall(node)
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        checkNestedCall(Syntax(node))
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterClauseSyntax) -> SyntaxVisitorContinueKind {
        checkNestedCall(Syntax(node))
        return .visitChildren
    }

    override func visit(_ node: TupleTypeElementSyntax) -> SyntaxVisitorContinueKind {
        if let label = node.secondName ?? node.firstName { checkSymbolLabel(label) }
        return .visitChildren
    }

    override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
        checkArgument(node)
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = node.secondName ?? node.firstName
        checkSymbolLabel(name)
        if designTokens, let value = node.defaultValue?.value {
            checkNumericDeclaration(name, value: value)
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        checkMember(node)
        if isSelf(node.base) {
            record(node.declName.baseName.text, node)
        }
        return .visitChildren
    }

    func isSelf(_ expression: ExprSyntax?) -> Bool {
        guard let expression else { return false }
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text == "self" }
        if let optional = expression.as(OptionalChainingExprSyntax.self) { return isSelf(optional.expression) }
        return false
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        checkAttribute(node)
        return .visitChildren
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if !path.contains("Modules/Utilities/DependencyInjection/"), node.path.first?.name.text == "Injected" {
            emit(.noDirectInjectedImport, node)
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        checkVariable(node)
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if
            node.modifiers.contains(where: { $0.name.text == "private" }),
            let result = node.signature.returnClause?.type.as(SomeOrAnyTypeSyntax.self),
            result.someOrAnySpecifier.text == "some",
            result.constraint.firstToken(viewMode: .sourceAccurate)?.text == "View" {
            helpers.insert(node.name.text)
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        checkType(node.name.text, node.classKeyword)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        checkType(node.name.text, node.structKeyword)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        checkType(node.name.text, node.actorKeyword)
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        checkObservationTracking(node)
        if node.parent?.as(MemberAccessExprSyntax.self)?.declName.id != node.id {
            record(node.baseName.text, node)
        }
        return .visitChildren
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        checkString(node)
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        checkAssignment(node)
        return .visitChildren
    }

    func record(_ name: String, _ node: some SyntaxProtocol) {
        guard needsReferences else { return }
        var parent = node.parent
        var owner: SyntaxIdentifier?
        var movable = true
        var type: String?
        var view: SyntaxIdentifier?
        while let current = parent {
            if owner == nil {
                if
                    current.is(FunctionDeclSyntax.self) || current.is(InitializerDeclSyntax.self)
                    || current.is(DeinitializerDeclSyntax.self) || current.is(SubscriptDeclSyntax.self) {
                    owner = current.id
                } else if
                    let variable = current.as(VariableDeclSyntax.self),
                    variable.parent?.is(MemberBlockItemSyntax.self) == true {
                    owner = current.id
                    movable = variable.bindings.allSatisfy { $0.initializer == nil }
                }
            }
            if type == nil { type = typeName(current) }
            if
                view == nil, let structure = current.as(StructDeclSyntax.self),
                structure.inheritanceClause?.inheritedTypes
                    .contains(where: { inherited in
                        inherited.type.tokens(viewMode: .sourceAccurate).contains { $0.text == "View" }
                    }) == true {
                view = structure.id
            }
            parent = current.parent
        }
        references[name, default: []].append(
            Reference(
                line: line(node),
                owner: owner,
                type: type,
                view: view,
                movable: movable
            )
        )
    }

    func typeName(_ node: Syntax) -> String? {
        if let value = node.as(ClassDeclSyntax.self) { return value.name.text }
        if let value = node.as(StructDeclSyntax.self) { return value.name.text }
        if let value = node.as(ActorDeclSyntax.self) { return value.name.text }
        if let value = node.as(EnumDeclSyntax.self) { return value.name.text }
        if let value = node.as(ExtensionDeclSyntax.self) {
            return value.extendedType.trimmedDescription.split(separator: ".").last.map(String.init)
        }
        return nil
    }

    func ancestor(_ node: some SyntaxProtocol, matching predicate: (Syntax) -> Bool) -> Syntax? {
        var parent = node.parent
        while let current = parent {
            if predicate(current) { return current }
            parent = current.parent
        }
        return nil
    }

    func checkType(_ name: String, _ keyword: TokenSyntax) {
        if name.hasSuffix("TestContext") { contexts.append((name, line(keyword))) }
        guard
            path.hasSuffix(".tests.swift"), !["Given", "When", "Then"].contains(where: name.hasPrefix),
            ["Fake", "Mock", "Stub", "Spy"].contains(where: { name.hasPrefix($0) || name.hasSuffix($0) })
        else { return }
        let first = line(keyword)
        if
            !nearby("Spyable cannot", line: first), !nearby("Stubable cannot", line: first),
            !nearby("lint:allow-manual-double:", line: first) {
            emit(.manualTestDouble, first: first, affected: [first])
        }
    }

    func finish() {
        for (name, first) in rowCalls where helpers.contains(name) {
            if !nearby("lint:allow-view-helper-row:", line: first, above: 2, reason: true) {
                emit(.viewHelperInForeach, first: first, affected: [first])
            }
        }
        finishProperties()
        let stem = URL(fileURLWithPath: path).lastPathComponent.replacingOccurrences(of: ".tests.swift", with: "")
        guard
            path.hasSuffix(".tests.swift"), stem.hasSuffix("Interactor") || stem.hasSuffix("ViewModel"),
            !header("lint:ignore-test-context-file:") else { return }
        if contexts.isEmpty || !contexts.contains(where: { constructors.contains($0.0) }) {
            emit(.testContextSetup, first: contexts.first?.1 ?? firstTest ?? 1, affected: Set(1 ... rows.count))
        }
        for first in directSetup {
            emit(.testContextSetup, first: first, affected: [first])
        }
    }
}
