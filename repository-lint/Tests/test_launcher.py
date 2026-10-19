"""Exercise the cache and invocation boundary without compiling SwiftSyntax."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="repository lint ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.package = self.root / "tools" / "repository-lint"
        self.package.mkdir(parents=True)
        shutil.copy(Path(__file__).resolve().parents[1] / "run.sh", self.package)
        (self.package / "Sources").mkdir()
        for name in ("Package.swift", "Package.resolved", "Sources/Rule.swift"):
            (self.package / name).write_text("initial")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.toolchain = self.root / "Xcode"
        compiler = self.toolchain / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        compiler.parent.mkdir(parents=True)
        compiler.write_text("#!" + sys.executable + "\n" + """import os, pathlib, sys
root = pathlib.Path(os.environ["TEST_ROOT"])
with (root / "builds").open("a") as log:
    log.write("build\\n")
if (root / "fail").exists():
    sys.exit(1)
scratch = pathlib.Path(sys.argv[sys.argv.index("--scratch-path") + 1])
binary = scratch / "release/repository-lint"
binary.parent.mkdir(parents=True, exist_ok=True)
binary.write_text('#!/bin/bash\\nprintf "%s\\\\n" "$PWD" "$@"\\n')
binary.chmod(0o755)
""")
        compiler.chmod(0o755)
        self.environment = dict(os.environ, DEVELOPER_DIR=str(self.toolchain), TEST_ROOT=str(self.root))
        self.environment.pop("REPOSITORY_LINT_BUILD_DIR", None)
        # Apple's git shim consults DEVELOPER_DIR; the fake toolchain is only for Swift.
        shim = self.root / "bin/git"
        shim.parent.mkdir()
        shim.write_text('#!/bin/bash\nunset DEVELOPER_DIR\nexec /usr/bin/git "$@"\n')
        shim.chmod(0o755)
        self.environment["PATH"] = str(shim.parent) + os.pathsep + os.environ["PATH"]

    def run_launcher(self, *arguments, check=True):
        return subprocess.run([str(self.package / "run.sh"), *arguments], cwd=self.package,
                              env=self.environment, text=True, capture_output=True, check=check)

    def builds(self):
        return (self.root / "builds").read_text().splitlines()

    def test_caller_repository_arguments_and_warm_cache(self):
        result = self.run_launcher("--base", "branch with spaces")
        self.assertEqual(result.stdout.splitlines(), [str(self.root), "--base", "branch with spaces"])
        self.run_launcher()
        self.assertEqual(len(self.builds()), 1)

    def test_content_addition_deletion_and_older_checkout_invalidate(self):
        self.run_launcher()
        source = self.package / "Sources/Rule.swift"
        source.write_text("updated")
        os.utime(source, (1, 1))
        self.run_launcher()
        extra = self.package / "Sources/Extra.swift"
        extra.write_text("new rule")
        self.run_launcher()
        self.assertEqual(len(self.builds()), 3)
        # Deleting the rule returns to an already built version.
        extra.unlink()
        self.run_launcher()
        self.assertEqual(len(self.builds()), 3)
        (self.package / "Package.resolved").write_text("updated dependency")
        self.run_launcher()
        self.assertEqual(len(self.builds()), 4)

    def test_worktrees_share_the_cached_executable(self):
        self.run_launcher()
        git = ["git", "-C", str(self.root), "-c", "user.name=test", "-c", "user.email=test@example.com"]
        subprocess.run([*git, "add", "tools"], check=True, env=self.environment)
        subprocess.run([*git, "commit", "-qm", "tools"], check=True, env=self.environment)
        worktree = self.root / "second worktree"
        subprocess.run([*git, "worktree", "add", "-q", "--detach", str(worktree)], check=True, env=self.environment)
        launcher = worktree / "tools/repository-lint/run.sh"
        result = subprocess.run([str(launcher), "--all"], cwd=launcher.parent, env=self.environment,
                                text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.splitlines(), [str(worktree), "--all"])
        self.assertEqual(len(self.builds()), 1)

    def test_old_versions_are_pruned(self):
        for version in range(7):
            (self.package / "Sources/Rule.swift").write_text(f"version {version}")
            self.run_launcher()
        executables = [path for path in (self.root / ".git/repository-lint/bin").iterdir()]
        self.assertEqual(len(executables), 5)

    def test_failed_build_is_retried_and_lock_released(self):
        (self.root / "fail").touch()
        self.assertNotEqual(self.run_launcher(check=False).returncode, 0)
        self.assertFalse((self.root / ".git/repository-lint/build.lock").exists())
        self.assertEqual(list((self.root / ".git/repository-lint/bin").iterdir()), [])
        (self.root / "fail").unlink()
        self.run_launcher()
        self.assertEqual(len(self.builds()), 2)


if __name__ == "__main__":
    unittest.main()
