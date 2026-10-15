import Foundation
import Testing

private func execute(_ arguments: [String], in directory: URL) throws -> (Int32, String) {
    let process = Process()
    process.currentDirectoryURL = directory
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["SWIFTLINT_METRICS_DB"] = directory.appendingPathComponent(".git/lint.sqlite3").path
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

@Test func runnerFiltersDiffsAndIncludesUntrackedFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for arguments in [
        ["git", "init", "-b", "main"],
        ["git", "config", "user.name", "Lint Test"],
        ["git", "config", "user.email", "lint@example.invalid"],
    ] {
        let result = try execute(arguments, in: directory)
        #expect(result.0 == 0, "\(result.1)")
    }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let executable = ProcessInfo.processInfo.environment["REPOSITORY_LINT_BINARY"]
        ?? package.appendingPathComponent(".build/release/repository-lint").path
    let folder = directory.appendingPathComponent("Modules/Scenes/Example/Sources")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("Space View.swift")
    let baseline = "let icon = Image(systemName: \"xmark\")\nlet value = 1\n"
    try baseline.write(to: file, atomically: true, encoding: .utf8)
    #expect(try execute(["git", "add", "."], in: directory).0 == 0)
    #expect(try execute(["git", "commit", "-m", "fixture"], in: directory).0 == 0)
    #expect(try execute([executable, "--custom-only"], in: directory).0 == 0)
    let empty = try execute([executable, "--custom-only", "--json"], in: directory)
    #expect(empty.0 == 0)
    #expect(empty.1.trimmingCharacters(in: .whitespacesAndNewlines) == "[]")
    #expect(try execute([executable, "--all", "--custom-only"], in: directory).0 == 1)

    try baseline.replacingOccurrences(of: "value = 1", with: "value = 2").write(
        to: file,
        atomically: true,
        encoding: .utf8
    )
    #expect(try execute([executable, "--custom-only"], in: directory).0 == 0)
    try baseline.replacingOccurrences(of: "xmark", with: "checkmark").write(to: file, atomically: true, encoding: .utf8)
    let changed = try execute([executable, "--custom-only", "--json"], in: directory)
    #expect(changed.0 == 1)
    let diagnostics = try JSONSerialization.jsonObject(with: Data(changed.1.utf8)) as? [[String: Any]]
    #expect(diagnostics?.count == 1)
    #expect(diagnostics?.first?["rule"] as? String == "no_sf_symbols")

    // A changed closing line must still select the diagnostic on the opening line.
    let multiline = "let view = content.padding(\n    .horizontal,\n    12\n)\n"
    try multiline.write(to: file, atomically: true, encoding: .utf8)
    #expect(try execute(["git", "add", "."], in: directory).0 == 0)
    #expect(try execute(["git", "commit", "-m", "multiline fixture"], in: directory).0 == 0)
    try multiline.replacingOccurrences(of: ")\n", with: ") // changed\n").write(
        to: file,
        atomically: true,
        encoding: .utf8
    )
    let closing = try execute([executable, "--custom-only", "--json"], in: directory)
    #expect(closing.0 == 1)
    #expect(closing.1.contains("design_system_spacing"))

    // Consumer configuration must reach parallel inspection and formatter exclusions.
    let configuration = directory.appendingPathComponent("rules.json")
    try """
    {"designSystemPrefix":"Brand","colorFactory":"brand","designSystemModulePattern":"^Brand.+$",
     "formatExcludedPrefixes":["Modules/Scenes/Example/"]}
    """.write(to: configuration, atomically: true, encoding: .utf8)
    try "let color = BrandColor.Text.primary.opacity(0.5)\n".write(to: file, atomically: true, encoding: .utf8)
    let configured = try execute([executable, "--custom-only", "--rules-config", configuration.path], in: directory)
    #expect(configured.0 == 1)
    #expect(configured.1.contains("BrandColor"))
    // A newly added component is exempt without registering its module name.
    let newComponent = directory.appendingPathComponent("Modules/UIComponents/BrandNewControl/Sources")
    try FileManager.default.createDirectory(at: newComponent, withIntermediateDirectories: true)
    let newFile = newComponent.appendingPathComponent("Control.swift")
    try "let view = content.padding(12)\n".write(to: newFile, atomically: true, encoding: .utf8)
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let discovered = try execute([executable, "--custom-only", "--rules-config", configuration.path], in: directory)
    #expect(discovered.0 == 0, "\(discovered.1)")
    try FileManager.default.removeItem(at: newFile)
    let invalidPattern = """
    {"designSystemPrefix":"Brand","colorFactory":"brand","designSystemModulePattern":"[",
     "formatExcludedPrefixes":[]}
    """
    let invalidFile = directory.appendingPathComponent("invalid-pattern.json")
    try invalidPattern.write(to: invalidFile, atomically: true, encoding: .utf8)
    let invalid = try execute([executable, "--custom-only", "--rules-config", invalidFile.path], in: directory)
    #expect(invalid.0 == 1)
    #expect(invalid.1.contains("repository-lint:"))
    let nested = "let value = outer(inner(\n    value\n))\n"
    try nested.write(to: file, atomically: true, encoding: .utf8)
    #expect(try execute([executable, "--format-nested-calls", "--rules-config", configuration.path], in: directory).0 == 0)
    #expect(try String(contentsOf: file, encoding: .utf8) == nested)
    try "invalid json".write(to: configuration, atomically: true, encoding: .utf8)
    #expect(try execute([executable, "--custom-only", "--rules-config", configuration.path], in: directory).0 == 1)

    try baseline.write(to: file, atomically: true, encoding: .utf8)
    #expect(try execute(["git", "add", "."], in: directory).0 == 0)
    #expect(try execute(["git", "commit", "-m", "restore fixture"], in: directory).0 == 0)
    try "@Injected var service: Service\n".write(
        to: folder.appendingPathComponent("New.swift"),
        atomically: true,
        encoding: .utf8
    )
    let untracked = try execute([executable, "--custom-only"], in: directory)
    #expect(untracked.0 == 1)
    #expect(untracked.1.contains("no_direct_injected"))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/lint.sqlite3").path))
    #expect(try execute([executable, "--jobs", "0"], in: directory).0 == 1)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("New.swift"))
    try FileManager.default.removeItem(at: file)
    #expect(try execute([executable, "--custom-only"], in: directory).0 == 0)
}
