import Foundation
import RepositoryLint

struct CommandFailure: Error, CustomStringConvertible {
    let description: String
}

@discardableResult
func command(_ arguments: [String], capture: Bool = true) throws -> (Data, Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    if capture { process.standardOutput = pipe }
    try process.run()
    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    return (data, process.terminationStatus)
}

func git(_ arguments: String...) throws -> String {
    let (data, status) = try command(["git"] + arguments)
    guard status == 0
    else { throw CommandFailure(description: "git \(arguments.joined(separator: " ")) failed (\(status))") }
    guard let value = String(data: data, encoding: .utf8) else {
        throw CommandFailure(description: "git output is not valid UTF-8")
    }
    return value
}

func paths(_ value: String) -> [String] {
    value.split(separator: "\0").map(String.init)
}

struct Options {
    var configuration = LintConfiguration()
    var base = "main"
    var all = false
    var selfTest = false
    var format = false
    var customOnly = false
    var benchmark = 0
    var jobs = min(ProcessInfo.processInfo.activeProcessorCount, 4)
    var json = false

    var mode: String {
        if selfTest { return "self-test" }
        if format { return "format" }
        if benchmark > 0 { return "benchmark" }
        return all ? "all" : "diff"
    }

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--all": all = true
            case "--self-test": selfTest = true
            case "--format-nested-calls": format = true; all = true
            case "--custom-only": customOnly = true
            case "--json": json = true
            case "--rules-config", "--base", "--benchmark", "--jobs":
                index += 1
                guard index < arguments.count
                else { throw CommandFailure(description: "Missing value for \(argument)") }
                try applyValue(argument, arguments[index])
            case "--help", "-h":
                print(
                    "repository-lint [--base REF] [--all] [--self-test] [--custom-only] "
                        + "[--jobs N] [--benchmark N] [--json] [--format-nested-calls] [--rules-config FILE]"
                )
                exit(0)
            default: throw CommandFailure(description: "Unknown argument: \(argument)")
            }
            index += 1
        }
    }

    private mutating func applyValue(_ argument: String, _ value: String) throws {
        if argument == "--rules-config" {
            configuration = try JSONDecoder().decode(LintConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: value)))
            _ = try NSRegularExpression(pattern: configuration.designSystemModulePattern)
            return
        }
        if argument == "--base" { base = value; return }
        guard let number = Int(value), number > 0 else {
            throw CommandFailure(description: "\(argument) requires a positive integer")
        }
        if argument == "--jobs" {
            jobs = number
        } else {
            benchmark = number
            customOnly = true
        }
    }
}
