# repository-lint

A macOS Swift package for 23 SwiftSyntax checks, a changed-line Git runner,
standard SwiftLint integration, and a nested-call formatter. It parses each
file once, scans up to four files concurrently, sorts diagnostics, and records
SQLite timings. It is independent of the app's Swift package graph.

## Use it

Pin a `repository-lint-vX.Y.Z` release of Pitcrew as a submodule. From your
consumer repository, run:

```bash
Tools/pitcrew/repository-lint/run.sh --self-test
Tools/pitcrew/repository-lint/run.sh --base main
Tools/pitcrew/repository-lint/run.sh --all --custom-only --json
Tools/pitcrew/repository-lint/run.sh --format-nested-calls
```

Requires macOS 13+, an Xcode toolchain supporting Swift 6, Git, and standard
macOS command-line tools. Install SwiftLint separately and provide `.swiftlint.yml`
in your repository, or use `--custom-only`. SwiftSyntax is pinned in Package.swift.
The launcher builds a release binary on first use and runs it directly on warm
calls. Cold builds compile SwiftSyntax and can take several minutes.

The caller's Git repository supplies files and diffs. Tracked changes and
untracked Swift files are included; deleted files are ignored. Custom findings
are filtered to changed lines, including multiline spans. Standard SwiftLint
checks complete changed files. `--all` checks all tracked Swift files.

## Repository conventions

The rules assume `Modules/<category>/<module>/` source layout, `Generated/`
exemptions, `.tests.swift` tests, Interactor/ViewModel names, a DependencyInjection
wrapper, and shared CurrencyFormatting/PercentageFormatting modules. These are
opinionated reference rules. Read [ARCHITECTURE.md](ARCHITECTURE.md) before adapting
them to another architecture.

Public fixtures use neutral `DesignColor`, `DesignSpacing`, `DesignRadius`,
`DesignTypography` and `DesignText` names. Keep your own naming and module
name pattern in a JSON file and pass `--rules-config path/to/rules.json`.
See [examples/rules.json](examples/rules.json) for the complete schema. All four
fields are required when supplying a file; an invalid file fails the command.
The module pattern is a regular expression matched against names under
`Modules/UIComponents/`; new matching modules are exempt automatically. Use a
negative lookahead for any consumer that shares the prefix but should still be
checked, for example `^Design(?!Charts$).+$`. Invalid patterns fail before linting.
The options replace defaults. Configuration is passed to every parallel inspection;
it does not rewrite source, so diagnostic offsets remain unchanged. `--self-test`
always exercises the bundled neutral fixtures.

The configuration controls design-system names and module exemptions, the custom
color factory name, and generated paths excluded from nested-call formatting.
[examples/lint-swift-diff.sh](examples/lint-swift-diff.sh) and
[examples/mise.toml](examples/mise.toml) show consumer integration.

```bash
# Stable IDs and exact diagnostic lines for 351 examples across 23 rules:
./repository-lint/run.sh --self-test
# Build production first; tests run the CLI in temporary consumer Git repos:
REPOSITORY_LINT_BINARY="$(git rev-parse --path-format=absolute --git-common-dir)/repository-lint/build/release/repository-lint" \
swift test --package-path repository-lint \
  --scratch-path .build-tools/repository-lint-tests -c release
python3 repository-lint/Tests/test_launcher.py
# Custom-rule timings (exclude standard SwiftLint):
./repository-lint/run.sh --all --benchmark 5 --jobs 4
```

The native tests also run the examples with CRLF, leading blank lines, and
indentation, and cover diff filtering, untracked and deleted files, filenames
with spaces, JSON output, configurable naming, formatter exclusions, raw strings,
nested comments, modifier exemptions, and closure boundaries. Launcher tests
check cache reuse/invalidation and failed-build recovery without compiling Swift.

## Cache and metrics

The release cache lives in `repository-lint/` under the consumer's Git common
directory, so every worktree reuses the same executables. Each version is copied
with its resource bundles to `bin/<key>`, keyed by a hash of source and resource
contents, the file list, the manifest, lockfile, launcher and selected compiler;
switching back to an older release reuses its executable. The five most recently
used versions are kept. `REPOSITORY_LINT_CACHE_DIR` moves the whole cache and
`REPOSITORY_LINT_BUILD_DIR` selects a different absolute scratch path. Builds
serialize through a recoverable PID lock; warm calls do not lock.

Metrics default to `repository-lint/metrics.sqlite3` under the Git common directory,
shared across worktrees. Set `SWIFTLINT_METRICS_DB` to retain a consumer's existing
location. The schema preserves historical rows and reports custom wall time,
parse time and traversal time; parallel phase sums are not elapsed wall time.

## Add a rule

Add its stable identifier and message to `Sources/RepositoryLint/Rule.swift`,
inspect the appropriate syntax node in the shared visitor, and report through
`emit`. Add at least three named passing and failing cases to
`Sources/RepositoryLint/Resources/Examples.json`, including exceptions and paths.
Keep examples valid Swift so parser recovery does not hide missing checks.
Run the self-test, native tests and launcher tests before review.
