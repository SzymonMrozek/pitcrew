import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2]


class PushGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.remote = self.root / "remote.git"
        patterns = self.root / "forbidden-terms"
        patterns.write_text("PrivateProject\n")
        self.env = {**os.environ, "PITCREW_FORBIDDEN_TERMS": str(patterns)}
        self.git("init", "-q")
        self.git("config", "user.name", "Example Developer")
        self.git("config", "user.email", "developer@example.test")
        self.git("config", "core.hooksPath", ".githooks")
        for name in ("scripts/check-forbidden-terms.sh", ".githooks/pre-push"):
            destination = self.repo / name
            destination.parent.mkdir(exist_ok=True)
            shutil.copy2(SOURCE / name, destination)
        self.file = self.repo / "example.txt"
        self.file.write_text("Example App\n")
        self.commit("Initial example")
        self.git("init", "--bare", "-q", str(self.remote))
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "origin", "HEAD:refs/heads/main")

    def git(self, *args, check=True):
        return subprocess.run(
            ["git", *args], cwd=self.repo, env=self.env,
            text=True, capture_output=True, check=check,
        )

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def test_checks_pushed_branch_even_when_checkout_is_clean(self):
        clean = self.git("rev-parse", "HEAD").stdout.strip()
        self.file.write_text("PrivateProject\n")
        private = self.commit("Update example")
        self.git("checkout", "--detach", "-q", clean)
        result = self.git("push", "origin", f"{private}:refs/heads/feature", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Forbidden terms found in tracked files", result.stderr)
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/feature").stdout, "")

    def test_checks_pushed_commit_instead_of_dirty_checkout(self):
        self.file.write_text("PrivateProject\n")
        result = self.git("push", "origin", "HEAD:refs/heads/feature", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checks_annotated_tag_tree(self):
        clean = self.git("rev-parse", "HEAD").stdout.strip()
        self.file.write_text("PrivateProject\n")
        self.commit("Update example")
        self.git("tag", "-a", "example-v1", "-m", "Example release")
        self.git("checkout", "--detach", "-q", clean)
        result = self.git("push", "origin", "refs/tags/example-v1", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("ls-remote", "origin", "refs/tags/example-v1").stdout, "")

    def test_checks_commit_metadata(self):
        self.file.write_text("Updated example\n")
        self.commit("PrivateProject update")
        result = self.git("push", "origin", "HEAD:refs/heads/feature", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Forbidden terms found in commits", result.stderr)

    def test_checks_working_tree_without_arguments(self):
        self.file.write_text("PrivateProject\n")
        result = subprocess.run(
            ["scripts/check-forbidden-terms.sh"], cwd=self.repo, env=self.env,
            text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_invalid_tree_fails_closed(self):
        result = subprocess.run(
            ["scripts/check-forbidden-terms.sh", "HEAD", "missing-ref"],
            cwd=self.repo, env=self.env, text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_deleting_a_remote_ref_still_works(self):
        self.git("push", "origin", "HEAD:refs/heads/feature")
        self.git("push", "origin", ":refs/heads/feature")
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/feature").stdout, "")


if __name__ == "__main__":
    unittest.main()
