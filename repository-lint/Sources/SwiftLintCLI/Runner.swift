import Foundation
import RepositoryLint

struct FileResult {
    let path: String
    let inspection: Inspection
}

func inspectFiles(_ files: [String], jobs: Int, configuration: LintConfiguration) async throws -> [FileResult] {
    try await withThrowingTaskGroup(of: FileResult.self) { group in
        var next = files.makeIterator()
        func submit(_ path: String) {
            group.addTask {
                let source = try String(contentsOfFile: path, encoding: .utf8)
                return FileResult(path: path, inspection: inspect(path: path, source: source, configuration: configuration))
            }
        }
        for _ in 0 ..< min(jobs, files.count) {
            if let path = next.next() { submit(path) }
        }
        var results: [FileResult] = []
        while let result = try await group.next() {
            results.append(result)
            if let path = next.next() { submit(path) }
        }
        return results.sorted { $0.path < $1.path }
    }
}

func changedLines(base: String, untracked: [String]) throws -> [String: Set<Int>] {
    let diff = try git(
        "-c",
        "core.quotepath=false",
        "diff",
        "--unified=0",
        "--no-ext-diff",
        "--no-color",
        "--diff-filter=ACMR",
        base,
        "--",
        "*.swift"
    )
    let expression = try NSRegularExpression(pattern: #"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@"#)
    var result: [String: Set<Int>] = [:]
    var path: String?
    for row in diff.components(separatedBy: "\n") {
        if row.hasPrefix("+++ b/") {
            let header = String(row.dropFirst(6))
            path = header.hasSuffix("\t") ? String(header.dropLast()) : header
        } else if
            let path, let match = expression.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)),
            let startRange = Range(match.range(at: 1), in: row), let start = Int(row[startRange]) {
            let count = Range(match.range(at: 2), in: row).flatMap { Int(row[$0]) } ?? 1
            result[path, default: []].formUnion(count == 0 ? [max(start, 1)] : Set(start ..< (start + count)))
        }
    }
    for path in untracked where path.hasSuffix(".swift") {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        result[path] = Set(1 ... max(1, source.components(separatedBy: "\n").count))
    }
    return result
}

func run(_ options: Options) async throws -> Int32 {
    let started = DispatchTime.now().uptimeNanoseconds
    var metrics = Metrics()
    metrics.mode = options.mode
    metrics.baseRef = options.base
    defer {
        metrics.totalNS = DispatchTime.now().uptimeNanoseconds - started
        do { try metrics.save() } catch { fputs("Lint metrics: \(error)\n", stderr) }
    }
    metrics.baseSHA = try git("merge-base", options.base, "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    metrics.headSHA = try git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    metrics.branch = try git("branch", "--show-current").trimmingCharacters(in: .whitespacesAndNewlines)
    if options.selfTest {
        let failures = try checkExamples()
        for failure in failures {
            fputs("\(failure)\n", stderr)
        }
        if
            failures
                .isEmpty {
            try print(
                "SwiftSyntax rule self-test passed (\(ruleExamples().count) examples "
                    + "across \(Rule.allCases.count) rules)."
            )
        }
        metrics.exitCode = failures.isEmpty ? 0 : 1
        return metrics.exitCode
    }
    let untracked = try paths(git("ls-files", "--others", "--exclude-standard", "-z"))
    metrics
        .diffFiles =
        try Array(Set(paths(git("diff", "--name-only", "-z", metrics.baseSHA)) + untracked))
            .sorted()
    let candidates = try options.all ? paths(git("ls-files", "-z", "--", "*.swift")) : metrics.diffFiles
        .filter { $0.hasSuffix(".swift") }
    metrics.files = candidates.filter { FileManager.default.fileExists(atPath: $0) }.sorted()
    if options.format { return try formatFiles(&metrics, configuration: options.configuration) }
    if metrics.files.isEmpty {
        let message = options.all ? "SwiftLint: no Swift files." : "SwiftLint: no changed Swift files."
        print(options.json ? "[]" : message)
        metrics.exitCode = 0
        return 0
    }
    return try await checkFiles(options, untracked: untracked, metrics: &metrics)
}

func formatFiles(_ metrics: inout Metrics, configuration: LintConfiguration) throws -> Int32 {
    let excluded = [
        ".build/",
        ".build-tools/",
        "Derived/",
        "DerivedData/",
    ] + configuration.formatExcludedPrefixes
    var changed = 0
    for path in metrics.files where !excluded.contains(where: path.hasPrefix) {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let formatted = formatNestedCalls(source)
        if
            formatted !=
            source { try formatted.write(toFile: path, atomically: true, encoding: .utf8); changed += 1 }
    }
    print("Expanded nested calls in \(changed) Swift file(s).")
    metrics.exitCode = 0
    return 0
}

func checkFiles(_ options: Options, untracked: [String], metrics: inout Metrics) async throws -> Int32 {
    if
        !options
            .json {
        print("SwiftLint: checking \(metrics.files.count) \(options.all ? "tracked" : "changed") Swift file(s).")
    }
    if !options.customOnly {
        let lintStarted = DispatchTime.now().uptimeNanoseconds
        metrics.swiftlintExit = try command(
            ["swiftlint", "lint", "--quiet", "--strict", "--force-exclude", "--config", ".swiftlint.yml"] + metrics
                .files,
            capture: false
        ).1
        metrics.builtInNS = DispatchTime.now().uptimeNanoseconds - lintStarted
    }
    let touched = options.all ? [:] : try changedLines(base: metrics.baseSHA, untracked: untracked)
    var results: [FileResult] = []
    var samples: [Double] = []
    for _ in 0 ..< max(1, options.benchmark) {
        let start = DispatchTime.now().uptimeNanoseconds
        results = try await inspectFiles(metrics.files, jobs: options.jobs, configuration: options.configuration)
        metrics.customNS = DispatchTime.now().uptimeNanoseconds - start
        samples.append(Double(metrics.customNS) / 1_000_000)
    }
    try report(results, options: options, touched: touched, metrics: &metrics)
    if options.benchmark > 0 {
        let durations = samples.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        print("Custom rules: \(metrics.files.count) files, \(options.jobs) workers, milliseconds: \(durations).")
    }
    metrics.exitCode = (metrics.swiftlintExit ?? 0) != 0 || metrics.findings > 0 ? 1 : 0
    return metrics.exitCode
}

func report(_ results: [FileResult], options: Options, touched: [String: Set<Int>], metrics: inout Metrics) throws {
    var output: [[String: Any]] = []
    for result in results {
        metrics.parseNS += result.inspection.parseNS
        metrics.walkNS += result.inspection.walkNS
        for finding in result.inspection.findings
            where options.all || !finding.affected.isDisjoint(with: touched[result.path] ?? []) {
            metrics.findings += 1
            if options.json {
                output.append([
                    "path": result.path,
                    "rule": finding.rule.rawValue,
                    "line": finding.line,
                    "affected": finding.affected.sorted(),
                ])
            } else {
                print("\(result.path):\(finding.line): error: \(finding.rule.message(configuration: options.configuration)) (\(finding.rule.rawValue))")
            }
        }
    }
    if options.json { try print(json(output)) }
}

@main struct SwiftLintCLI {
    static func main() async {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            let status = try await run(options)
            exit(status)
        } catch {
            fputs("repository-lint: \(error)\n", stderr)
            exit(1)
        }
    }
}
