# Repository lint architecture

## Invariants

- Parse a file once with SwiftParser and run the rules in one shared visitor.
  Collect declaration/reference information only when dependency or binding checks
  need it. Nested-call formatting uses a separate visitor and UTF-8 insertion offsets.
- Keep stable rule IDs, exception markers, diagnostic lines and affected-line spans.
  A changed closing line can select a diagnostic on an unchanged opening line.
- Limit concurrent files, then sort output by path, rule and line. A slow worker
  must not change output order. Configuration is immutable within each inspection.
- Git selection belongs to the consumer repository, never the tool checkout.
  Include untracked Swift files, handle spaces, and skip deleted files.
- Keep production build artifacts separate from test builds. Warm invocations
  must execute the release binary without invoking SwiftPM.
- Bundle examples with the package so downstream self-tests exercise exactly the
  rules being shipped. Consumer naming must not change the bundled fixtures.
- Preserve SQLite metric compatibility and record failed invocations too.

## Boundaries

`RepositoryLint` owns parsing, rule definitions, naming configuration, examples,
and nested-call expansion. `SwiftLintCLI` owns Git, arguments, changed-line
filtering, standard SwiftLint execution, reporting, and metrics. `run.sh` owns
cached compilation. Consumers own their SwiftLint version/configuration and their
repository-specific names and exemption patterns. No app dependency is introduced.

The current rules intentionally retain their modular SwiftUI architecture
conventions. Names and design-system exemptions are configuration; other repository
layout conventions are source-level adaptation points. This is a reference tool,
not a general-purpose lint plugin framework.

## Pitfalls

- Compiler/toolchain changes and deleted files must invalidate cached executables.
  Content hashes also catch switching to an older release with preserved mtimes.
- Keep the cache key free of absolute paths. Worktrees have different package
  paths, and a path-dependent key rebuilds SwiftSyntax in every new worktree.
- Copy resource bundles next to the cached executable. `Bundle.module` looks
  beside the executable before the original build directory.
- Don't rewrite token names in source to customize rules: that shifts diagnostic
  columns and UTF-8 offsets. Pass naming configuration into the visitor instead.
- Standard SwiftLint checks whole changed files; only the custom checks use line
  filtering. Preserve that distinction when selecting files.
- Don't format generated protobufs. Consumers supply their generated-code prefixes;
  build output directories are excluded by default.
- An old build lock can outlive a killed compiler. Use a stale-PID-aware lock and
  remove it when compilation fails. Keep warm runs out of the lock path.
- Tests execute the production binary from temporary Git repositories. Build it
  first and pass `REPOSITORY_LINT_BINARY` when using a separate scratch directory.
- `--self-test` tests bundled neutral names even if the consumer passes its own
  configuration. Otherwise a private naming scheme would break public fixtures.
