import CSQLite
import Foundation

func json(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

struct Metrics {
    var startedAt = ISO8601DateFormatter().string(from: Date())
    var worktree = FileManager.default.currentDirectoryPath
    var branch = ""
    var baseRef = ""
    var baseSHA = ""
    var headSHA = ""
    var mode = "diff"
    var diffFiles: [String] = []
    var files: [String] = []
    var builtInNS: UInt64?
    var customNS: UInt64 = 0
    var parseNS: UInt64 = 0
    var walkNS: UInt64 = 0
    var swiftlintExit: Int32?
    var findings = 0
    var totalNS: UInt64 = 0
    var exitCode: Int32 = 1

    func save() throws {
        let database: String
        if let configured = ProcessInfo.processInfo.environment["SWIFTLINT_METRICS_DB"] {
            database = configured
        } else {
            let common = try git("rev-parse", "--path-format=absolute", "--git-common-dir")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            database = URL(fileURLWithPath: common)
                .appendingPathComponent("repository-lint/metrics.sqlite3").path
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: database).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var connection: OpaquePointer?
        guard sqlite3_open(database, &connection) == SQLITE_OK
        else { throw CommandFailure(description: "Cannot open lint metrics database") }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 30000)
        func execute(_ sql: String) throws {
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
                throw CommandFailure(description: String(cString: sqlite3_errmsg(connection)))
            }
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS lint_runs (
            id INTEGER PRIMARY KEY, started_at TEXT NOT NULL, worktree TEXT NOT NULL,
            branch TEXT NOT NULL, base_ref TEXT NOT NULL, base_sha TEXT NOT NULL,
            head_sha TEXT NOT NULL, mode TEXT NOT NULL, diff_files_json TEXT NOT NULL,
            linted_files_json TEXT NOT NULL, built_in_ns INTEGER, custom_ns_json TEXT NOT NULL,
            swiftlint_exit_code INTEGER, custom_findings INTEGER NOT NULL,
            total_ns INTEGER NOT NULL, exit_code INTEGER NOT NULL
        )
        """)
        try execute("BEGIN IMMEDIATE")
        // Older rows remain readable; shared traversal is now timed as one pipeline.
        var schema: OpaquePointer?
        sqlite3_prepare_v2(connection, "PRAGMA table_info(lint_runs)", -1, &schema, nil)
        var columns: Set<String> = []
        while sqlite3_step(schema) == SQLITE_ROW {
            columns.insert(String(cString: sqlite3_column_text(schema, 1)))
        }
        sqlite3_finalize(schema)
        for column in ["custom_total_ns", "parse_ns", "shared_walk_ns"] where !columns.contains(column) {
            try execute("ALTER TABLE lint_runs ADD COLUMN \(column) INTEGER")
        }
        let values: [Any?] = try [
            startedAt, worktree, branch,
            baseRef,
            baseSHA,
            headSHA,
            mode,
            json(diffFiles),
            json(files),
            builtInNS,
            json(["swift_syntax_parse": parseNS, "shared_syntax_walk": walkNS]),
            swiftlintExit,
            findings,
            totalNS,
            exitCode,
            customNS,
            parseNS,
            walkNS,
        ]
        var statement: OpaquePointer?
        let fields = [
            "started_at", "worktree", "branch", "base_ref", "base_sha", "head_sha", "mode",
            "diff_files_json", "linted_files_json", "built_in_ns", "custom_ns_json", "swiftlint_exit_code",
            "custom_findings", "total_ns", "exit_code", "custom_total_ns", "parse_ns", "shared_walk_ns",
        ]
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
        let sql = "INSERT INTO lint_runs (\(fields.joined(separator: ","))) VALUES (\(placeholders))"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK
        else { throw CommandFailure(description: String(cString: sqlite3_errmsg(connection))) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            bind(value, position: Int32(index + 1), statement: statement)
        }
        guard sqlite3_step(statement) == SQLITE_DONE
        else { throw CommandFailure(description: String(cString: sqlite3_errmsg(connection))) }
        try execute("COMMIT")
    }

    private func bind(_ value: Any?, position: Int32, statement: OpaquePointer?) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let string = value as? String {
            sqlite3_bind_text(statement, position, string, -1, transient)
        } else if let number = value as? UInt64 {
            sqlite3_bind_int64(statement, position, Int64(number))
        } else if let number = value as? Int {
            sqlite3_bind_int64(statement, position, Int64(number))
        } else if let number = value as? Int32 {
            sqlite3_bind_int(statement, position, number)
        } else {
            sqlite3_bind_null(statement, position)
        }
    }
}
