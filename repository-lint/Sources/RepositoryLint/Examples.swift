import Foundation

public struct RuleExample: Decodable {
    public let rule: Rule
    public let name: String
    public let path: String
    public let source: String
    public let lines: [Int]
    public let affected: [[Int]]?
}

public func ruleExamples() throws -> [RuleExample] {
    let url = Bundle.module.url(forResource: "Examples", withExtension: "json")!
    return try JSONDecoder().decode([RuleExample].self, from: Data(contentsOf: url))
}

public func checkExamples() throws -> [String] {
    var failures: [String] = []
    let examples = try ruleExamples()
    for rule in Rule.allCases {
        let matching = examples.filter { $0.rule == rule }
        if matching.count(where: { $0.lines.isEmpty }) < 3 || matching.count(where: { !$0.lines.isEmpty }) < 3 {
            failures.append("\(rule.rawValue): add at least three passing and failing examples")
        }
        if Set(matching.map(\.name)).count != matching.count {
            failures.append("\(rule.rawValue): duplicate example name")
        }
    }
    for example in examples {
        let inspection = inspect(path: example.path, source: example.source)
        let findings = inspection.findings.filter { $0.rule == example.rule }
        let actual = findings.map(\.line).sorted()
        if actual != example.lines.sorted() {
            failures.append("\(example.rule.rawValue)/\(example.name): expected \(example.lines), got \(actual)")
        }
        if findings.contains(where: { !$0.affected.contains($0.line) }) {
            failures.append("\(example.rule.rawValue)/\(example.name): diagnostic missing from affected lines")
        }
        failures += checkAffectedLines(example, findings: findings)
        if example.rule == .nestedCallArguments {
            let formatted = formatNestedCalls(example.source)
            if
                !inspect(path: example.path, source: formatted).breaks
                    .isEmpty || formatNestedCalls(formatted) != formatted {
                failures.append("nested_call_arguments/\(example.name): formatter failed or is not idempotent")
            }
        }
    }
    return failures
}

private func checkAffectedLines(_ example: RuleExample, findings: [Finding]) -> [String] {
    var failures: [String] = []
    for (first, covered) in zip(example.lines, example.affected ?? [])
        where !findings.contains(where: { $0.line == first && Set(covered).isSubset(of: $0.affected) }) {
        failures.append("\(example.rule.rawValue)/\(example.name): omitted affected lines \(covered)")
    }
    return failures
}
