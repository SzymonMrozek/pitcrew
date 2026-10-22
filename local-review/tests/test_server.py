"""Tests use throwaway Git repositories and never merge the real project."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil
import secrets
import shlex
import socket
import struct
import time
import threading
import unittest
import urllib.request
import urllib.error
from unittest.mock import patch

TOOL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOL))
from agent import deliver, deliver_review  # noqa: E402

spec = importlib.util.spec_from_file_location('review_server', TOOL / 'server.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
parent_agent_impl = m.parent_agent


def run_launcher(args, store, timeout=30):
    """Run the launcher; on a hang, dump launcher and server stacks so CI shows where it waits."""
    import signal
    env = {**os.environ, 'PYTHONFAULTHANDLER': '1'}
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        servers = [int(line.split()[0]) for line in subprocess.run(['ps', '-ax', '-o', 'pid,command'], capture_output=True, text=True).stdout.splitlines()
                   if '--serve' in line and 'server.py' in line]
        for pid in (process.pid, *servers):
            if pid:
                try:
                    os.kill(pid, signal.SIGABRT)
                except OSError:
                    pass
        stdout, stderr = process.communicate()
        time.sleep(1)
        log = (store / 'shared-server.log').read_text() if (store / 'shared-server.log').exists() else ''
        ps = subprocess.run(['ps', '-ax', '-o', 'pid,ppid,stat,etime,command'], capture_output=True, text=True).stdout
        raise AssertionError(f'Launcher hung.\nstdout:\n{stdout}\nstderr:\n{stderr}\nserver log:\n{log}\n'
                             f'metadata: {read_json_safely(store / "shared-server.json")}\nprocesses:\n'
                             + '\n'.join(line for line in ps.splitlines() if 'python' in line or 'git' in line))
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


def movie(seconds, long=False, timescale=600):
    """A minimal finished QuickTime file: ftyp, media data and a movie header with the given duration."""
    if long:
        header = b'\1\0\0\0' + bytes(16) + struct.pack('>IQ', timescale, round(seconds * timescale))
    else:
        header = bytes(12) + struct.pack('>II', timescale, round(seconds * timescale))
    mvhd = struct.pack('>I4s', 8 + len(header) + 80, b'mvhd') + header + bytes(80)
    return (struct.pack('>I4s', 16, b'ftyp') + b'qt  ' + bytes(4) + struct.pack('>I4s', 12, b'mdat') + bytes(4)
            + struct.pack('>I4s', 8 + len(mvhd), b'moov') + mvhd)


# Stands in for `simctl io recordVideo`: announces the recording and writes the movie only when interrupted.
FAKE_RECORDER = '''
import signal, sys, time
def stop(*_):
    sys.stderr.write('Recording completed. Writing to disk.\\n')
    open(sys.argv[-1], 'wb').write(MOVIE)
    sys.exit(0)
signal.signal(signal.SIGINT, stop)
sys.stderr.write('Recording started\\n')
sys.stderr.flush()
while True:
    time.sleep(.05)
'''.replace('MOVIE', repr(movie(4.25)))


def read_json_safely(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-b', 'main')
        self.git('config', 'user.email', 'test@example.com')
        self.git('config', 'user.name', 'Test')
        self.write('Interactor.swift', 'let value = 1\n')
        self.git('add', '.')
        self.git('commit', '-m', 'feat(test): initial')
        self.git('checkout', '-b', 'feature')
        self.write('Interactor.swift', 'let value = 2\n')
        self.env = patch.dict(os.environ, {}, clear=False)
        self.env.start()
        os.environ.pop('JEV_API_KEY', None)
        for name in ('CLAUDECODE', 'CLAUDE_CODE_SESSION_ID', 'LOCAL_REVIEW_HANDOFF', 'LOCAL_REVIEW_CONFIG'):
            os.environ.pop(name, None)
        homes = tempfile.TemporaryDirectory()
        self.addCleanup(homes.cleanup)
        self.homes = Path(homes.name)
        os.environ.update(CODEX_THREAD_ID='original-codex-chat', CODEX_CLI_PATH='/fake/codex',
                          CODEX_HOME=str(self.homes / 'codex'), CLAUDE_CONFIG_DIR=str(self.homes / 'claude'))
        ancestry = patch.object(m, 'parent_agent', return_value=None)
        ancestry.start()
        self.addCleanup(ancestry.stop)
        self.addCleanup(self.env.stop)
        self.review = m.Review(self.root, 'main')
        self.review.record_agent()
        self.notifier = patch.object(m.Review, 'notify_merge_request')
        self.notify = self.notifier.start()
        self.addCleanup(self.notifier.stop)

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.root, capture_output=True, text=True, check=True).stdout.strip()

    def write(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def test_capture_includes_committed_staged_unstaged_untracked_deleted_and_modes(self):
        self.git('add', '.')
        self.git('commit', '-m', 'fix(test): committed')
        self.write('Interactor.swift', 'let value = 3\n')
        self.git('add', '.')
        self.write('Interactor.swift', 'let value = 4\n')
        self.write('new.txt', 'untracked\n')
        self.review.refresh()
        self.assertEqual(len(self.review.files), 2)
        self.assertIn('let value = 4', self.review.files[0]['patch'])
        self.assertIn('let value = 1', self.review.files[0]['patch'])
        self.assertNotIn('let value = 3', self.review.files[0]['patch'])
        original = self.review.revision
        self.git('add', '--all')
        self.review.refresh()
        self.assertEqual(self.review.revision, original, 'Staging alone must not invalidate content approval')
        (self.root / 'Interactor.swift').chmod(0o755)
        self.review.refresh()
        self.assertNotEqual(self.review.revision, original)
        (self.root / 'Interactor.swift').unlink()
        self.review.refresh()
        self.assertEqual(self.review.files[0]['status'], 'D')

    def test_diff_has_correct_side_line_numbers(self):
        rows = m.diff_rows('a\nb\nc\n', 'a\nB\nc\nd\n')
        removed = next(row for row in rows if row['type'] == 'delete')
        added = next(row for row in rows if row['type'] == 'add')
        self.assertEqual((removed['old'], removed['new']), (2, None))
        self.assertEqual((added['old'], added['new']), (None, 2))
        self.assertEqual(rows[-1]['new'], 4)
        self.assertEqual(m.diff_rows('', 'first\n')[-1]['new'], 1)
        self.assertIn('newline', m.diff_rows('a', 'a\n')[0]['text'])

    def test_filters_keep_snapshots_visible_under_tests(self):
        self.assertEqual(m.category('Modules/Tests/__Snapshots__/a.tests/image.png'), 'snapshot')
        self.assertEqual(m.category('Modules/Sources/X.tests.swift'), 'test')
        self.assertEqual(m.category('Resources/en.lproj/Localizable.strings'), 'localization')
        self.assertEqual(m.category('Sources/Generated/Strings.swift'), 'localization')
        self.assertEqual(m.category('Views/Thing.swift'), 'view')
        self.assertEqual(m.category('Modules/X/Views/Thing.swift'), 'view')
        self.assertEqual(m.category('Modules/Scenes/Accounts/Implementation/Sources/L10n.swift'), 'localization')
        self.assertEqual(m.category('Modules/Models/Asset/Project.swift'), 'manifest')
        self.assertEqual(m.category('Project.swift'), 'manifest')
        self.assertEqual(m.category('Sources/ProjectSettings.swift'), 'code')
        self.assertTrue(m.DEFAULTS['hideManifests'])

    def test_generated_protobuf_code_is_hidden_and_ranked_lowest(self):
        for path in ('Modules/Models/Proto/Sources/Generated/user/v2/user.pb.swift', 'Sources/Generated/api.grpc.swift',
                     'api/user.pb.go', 'api/user_grpc.pb.go', 'service/user_pb2.py', 'web/user_pb.d.ts'):
            self.assertEqual(m.category(path), 'generated', path)
            self.assertEqual(m.fallback_score(path), 10, path)
        self.assertEqual(m.category('Sources/ProtobufMapping.swift'), 'code')
        self.assertTrue(m.DEFAULTS['hideGenerated'])
        with self.assertRaises(ValueError):
            self.review.update_settings({'hideGenerated': 'yes'})
        self.write('Sources/user.pb.swift', 'struct User {}\n')
        self.review.refresh()
        file = next(f for f in self.review.files if f['path'] == 'Sources/user.pb.swift')
        self.assertEqual(file['kind'], 'generated')
        with patch.dict(os.environ, {'JEV_API_KEY': 'test'}), patch.object(m.urllib.request, 'urlopen') as urlopen:
            self.review.files = [file]
            self.review.rank()
        urlopen.assert_not_called()
        self.assertEqual((self.review.ranking['fallbacks'], file['scorer']), (0, 'Fallback'))

    def test_queue_snapshot_matches_a_live_submodule_pin_and_rejects_dirty_execution(self):
        dependency = self.root / 'Tools/Dependency'
        dependency.mkdir(parents=True)
        self.git('-C', str(dependency), 'init', '-b', 'main')
        self.git('-C', str(dependency), 'config', 'user.name', 'Test')
        self.git('-C', str(dependency), 'config', 'user.email', 'test@example.com')
        self.write('Tools/Dependency/version.txt', 'one\n')
        self.git('-C', str(dependency), 'add', '.')
        self.git('-C', str(dependency), 'commit', '-m', 'feat(test): first release')
        first = self.git('-C', str(dependency), 'rev-parse', 'HEAD')
        self.git('update-index', '--add', '--cacheinfo', f'160000,{first},Tools/Dependency')
        self.git('commit', '-m', 'chore(test): pin first release')
        self.git('update-ref', 'refs/heads/main', 'HEAD')
        self.write('Tools/Dependency/version.txt', 'two\n')
        self.git('-C', str(dependency), 'commit', '-am', 'feat(test): second release')
        second = self.git('-C', str(dependency), 'rev-parse', 'HEAD')
        self.review.refresh()
        self.assertTrue(self.review.state()['canMerge'])
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        live = next(file for file in self.review.files if file['path'] == 'Tools/Dependency')
        captured = self.review.capture(before=request['snapshotBase'], after=request['snapshotCommit'])
        saved = next(file for file in captured[3] if file['path'] == 'Tools/Dependency')
        self.assertEqual(live['fingerprint'], saved['fingerprint'])
        self.assertEqual(self.review.blobs[live['id']]['new'], (second + '\n').encode())
        self.assertEqual(captured[4][saved['id']]['new'], (second + '\n').encode())
        self.assertEqual(self.git('rev-parse', request['snapshotRef'] + ':Tools/Dependency'), second)
        self.write('Tools/Dependency/version.txt', 'uncommitted\n')
        self.review.refresh()
        self.assertFalse(self.review.state()['canMerge'])
        with self.assertRaisesRegex(ValueError, 'uncommitted submodule'):
            self.review.request_merge(self.review.approval_revision(), '', '')
        with self.assertRaisesRegex(ValueError, 'uncommitted submodule'):
            self.review.start_merge(self.review.revision, 'fix(test): pin dependency', 'Keep dirty submodules out.')

    def test_saved_trees_with_submodule_commits_are_readable(self):
        # The superproject never has the submodule's commit objects; only the gitlink.
        old_link, new_link = '1' * 40, '2' * 40
        self.git('checkout', 'main')
        self.git('update-index', '--add', '--cacheinfo', f'160000,{old_link},vendor/tool')
        self.git('commit', '-m', 'chore(test): add submodule')
        base = self.git('rev-parse', 'HEAD')
        self.git('update-index', '--cacheinfo', f'160000,{new_link},vendor/tool')
        self.git('commit', '-m', 'chore(test): bump submodule')
        _, _, _, files, blobs, _ = self.review.capture(base, self.git('rev-parse', 'HEAD'))
        link = next(f for f in files if f['path'] == 'vendor/tool')
        blobs = blobs[link['id']]
        self.assertEqual((blobs['old'].strip(), blobs['new'].strip()), (old_link.encode(), new_link.encode()))

    def test_priority_paths_keep_high_priority_over_evaluated_scores(self):
        interface = 'Modules/Scenes/Accounts/Interface/Sources/AccountsInterface.swift'
        self.assertEqual(m.fallback_score(interface), 60, 'Nothing is prioritized without configuration')
        self.write('.config/local-review.toml', "[[priority]]\npattern = '^Modules/[^/]+/[^/]+/Interface/'\nlabel = 'Interface target'\n")
        config = m.load_config(self.root)
        self.assertEqual(m.fallback_score(interface, config), m.PRIORITY_SCORE)
        self.assertEqual(m.fallback_score('Modules/Scenes/Accounts/Interface/Tests/AccountsTests.swift', config), 10)
        self.assertEqual(m.fallback_score('Modules/Scenes/Accounts/Implementation/Sources/Thing.swift', config), 60)
        self.write(interface, 'public protocol Accounts {}\n')
        self.write('Sources/AuthService.swift', 'let auth = 1\n')
        self.review.refresh()
        file = next(f for f in self.review.files if f['path'] == interface)
        self.review.cache[self.review.score_key(file)] = {'score': 12, 'signals': {'business': 12, 'performance': 0, 'ui': 0}}
        self.review.apply_scores()
        self.assertEqual((file['score'], file['scorer'], file['priority']), (m.PRIORITY_SCORE, 'Jev', 'Interface target'))
        self.assertEqual(self.review.files[0]['path'], interface)
        self.assertNotIn('priority', next(f for f in self.review.files if f['path'] == 'Sources/AuthService.swift'))

    def test_data_models_keep_high_priority_over_evaluated_scores(self):
        model = 'Modules/Scenes/Portfolio/Implementation/Sources/Scenes/PortfolioDashboard/PortfolioDashboardContent.swift'
        for path in (model, 'Modules/Models/UserPortfolio/Sources/UserPortfolio.swift', 'Sources/AccountState.swift', 'app/models/user.py'):
            self.assertEqual(m.priority(path), ('Data model', m.MODEL_SCORE), path)
            self.assertEqual(m.fallback_score(path), m.MODEL_SCORE, path)
        for path in ('Sources/ContentView.swift', 'Modules/Models/Proto/Sources/user.pb.swift', 'Modules/Models/Asset/Tests/AssetTests.swift',
                     'Sources/ContentLoader.swift'):
            self.assertIsNone(m.priority(path), path)
        self.write('.config/local-review.toml', "[[priority]]\npattern = '/Interface/'\nlabel = 'Interface target'\n")
        self.assertEqual(m.priority('Modules/Accounts/Interface/AccountState.swift', m.load_config(self.root)), ('Interface target', m.PRIORITY_SCORE))
        self.write('.config/local-review.toml', "[files]\nmodel = []\n")
        self.assertIsNone(m.priority(model, m.load_config(self.root)))
        (self.root / '.config/local-review.toml').unlink()
        self.write(model, 'struct PortfolioDashboardContent {}\n')
        self.review.refresh()
        file = next(f for f in self.review.files if f['path'] == model)
        self.review.cache[self.review.score_key(file)] = {'score': 20, 'signals': {'business': 20, 'performance': 0, 'ui': 0}}
        self.review.apply_scores()
        self.assertEqual((file['score'], file['scorer'], file['priority']), (m.MODEL_SCORE, 'Jev', 'Data model'))
        self.review.cache[self.review.score_key(file)] = {'score': 92, 'signals': {'business': 92, 'performance': 0, 'ui': 0}}
        self.review.apply_scores()
        self.assertEqual(file['score'], 92, 'A higher evaluated score is kept')

    def test_configuration_overrides_defaults_and_rejects_unknown_settings(self):
        self.write('.config/local-review.toml', "name = 'team-review'\ntitle = 'Team'\nlauncher = 'make review --'\n"
                   "[files]\nmanifest = ['(^|/)BUILD$']\n[[modules]]\npattern = '^Packages/(?<name>[^/]+)/'\n"
                   "[merge]\ncommand = ['git', 'merge', '{target}']\n")
        config = m.load_config(self.root)
        self.assertEqual(m.category('Sources/BUILD', config), 'manifest')
        self.assertEqual(m.category('Project.swift', config), 'code')
        self.assertEqual(config['files']['test'], m.CONFIG['files']['test'], 'Unset keys keep their defaults')
        review = m.Review(self.root, 'main')
        self.assertEqual(review.store, Path(self.git('rev-parse', '--path-format=absolute', '--git-common-dir')) / 'team-review')
        self.assertEqual(review.state()['tool'], {'title': 'Team', 'launcher': 'make review --', 'modules': ['^Packages/(?<name>[^/]+)/']})
        review.snapshot('probe')
        self.assertTrue(self.git('rev-parse', f'refs/team-review/{review.session_id}/probe'))
        self.assertEqual(m.env_prefix(config['name']), 'TEAM_REVIEW')
        with patch.dict(os.environ, {'LOCAL_REVIEW_CONFIG': str(TOOL / 'examples/local-review.toml')}):
            example = m.load_config(self.root)
        self.assertEqual((example['title'], example['merge']['checks'][0]['command']), ('MyApp', ['mise', 'run', 'app:run:worktree']))
        self.assertEqual(example['demos']['paths'], ['^(App|Modules)/'])
        for invalid in ("unknown = 1\n", "[merge]\nunknown = 1\n", "name = 'Bad Name'\n", "[files]\nview = ['(']\n", "name = \n",
                        "[demos]\npaths = ['(']\n", "[demos]\nunknown = 1\n"):
            self.write('.config/local-review.toml', invalid)
            with self.assertRaises((ValueError, m.re.error)):
                m.load_config(self.root, strict=True)

    def test_builds_that_do_not_own_the_configuration_skip_settings_they_do_not_know(self):
        self.write('.config/local-review.toml', "title = 'Team'\nfuture = 1\n[merge]\ninstructions = 'Rebase first.'\nlater = 1\n"
                   "[launch]\ncommand = ['run']\n")
        with self.assertRaisesRegex(ValueError, "Unknown setting 'future', 'merge.later', 'launch'"):
            m.load_config(self.root, strict=True)
        with patch.object(m, 'ASSETS', self.root.resolve() / 'Tools/review'):
            self.assertTrue(m.owns_config(self.root), 'The checked-out tool owns its repository configuration')
            with self.assertRaisesRegex(ValueError, 'Unknown setting'):
                m.load_config(self.root)
        with patch.object(m, 'ASSETS', self.root.resolve() / '.git/local-review/runtime/v1'):
            self.assertFalse(m.owns_config(self.root), 'Merge workers run a copy stored in the Git common directory')
        self.assertFalse(m.owns_config(self.root), 'A shared server launched from another worktree')
        with patch('sys.stderr', new=io.StringIO()) as stderr:
            config = m.load_config(self.root)
            m.Review(self.root, 'main').refresh()
        self.assertEqual((config['title'], config['merge']['instructions']), ('Team', 'Rebase first.'), 'Known settings still apply')
        self.assertNotIn('future', config)
        self.assertNotIn('later', config['merge'])
        self.assertEqual(stderr.getvalue().count('Ignoring settings'), 1, 'Each refresh rereads the file; the warning appears once')
        self.assertIn('future, merge.later, launch', stderr.getvalue())
        self.write('.config/local-review.toml', "merge = 'wt merge'\n")
        with self.assertRaisesRegex(ValueError, r'\[merge\] .* must be a table'):
            m.load_config(self.root)

    def test_settings_and_viewed_state_persist_and_revision_changes(self):
        self.review.update_settings({**m.DEFAULTS, 'exclude': ['*/Generated/*'], 'imageScale': 60})
        file = self.review.files[0]
        self.review.session['viewed'][file['id']] = file['fingerprint']
        self.review.save_session()
        second = m.Review(self.root, 'main')
        self.assertEqual(second.settings['imageScale'], 60)
        self.assertEqual(second.session['viewed'][file['id']], file['fingerprint'])
        self.write('Interactor.swift', 'changed\n')
        second.refresh()
        self.assertNotEqual(second.files[0]['fingerprint'], second.session['viewed'][file['id']])

    def test_feedback_is_shared_and_survives_worktree_removal(self):
        worktree = self.root / 'temporary-review'
        self.git('worktree', 'add', '-b', 'feedback-branch', str(worktree))
        (worktree / 'Interactor.swift').write_text('let value = 7\n')
        review = m.Review(worktree, 'main', auto_rank=False)
        file = review.files[0]
        inbox = review.save_feedback('  Make snapshot review faster  ', file['id'])
        directory = Path(inbox['directory'])
        self.assertFalse(directory.is_relative_to(worktree))
        self.assertEqual(inbox['entries'][0]['path'], 'Interactor.swift')
        self.git('worktree', 'remove', '--force', str(worktree))
        second = m.Review(self.root, 'main', auto_rank=False)
        entries = second.feedback()['entries']
        self.assertEqual(entries[0]['text'], 'Make snapshot review faster')
        self.assertEqual(entries[0]['branch'], 'feedback-branch')
        second.save_feedback('Keep code scrolling too')
        self.assertEqual(len(review.feedback()['entries']), 2)
        for text in ('', '  ', 7, 'a' * 10001):
            with self.assertRaises(ValueError):
                second.save_feedback(text)
        with self.assertRaisesRegex(ValueError, 'Invalid feedback file'):
            second.save_feedback('Invalid context', '../../outside')

    def test_tool_feedback_accepts_stale_optional_file_context(self):
        file_id = self.review.files[0]['id']
        self.git('checkout', '--', 'Interactor.swift')
        self.review.refresh()
        entry = self.review.save_feedback('Keep my feedback even after the file disappears', file_id)['entries'][0]
        self.assertIsNone(entry['path'])
        self.assertEqual(entry['text'], 'Keep my feedback even after the file disappears')

    def test_thread_scope_excludes_dependencies_including_same_file_between_interactions(self):
        self.write('Dependency.swift', 'imported dependency\n')
        self.write('Interactor.swift', 'dependency before\n' + '\n'.join(f'line {n}' for n in range(20)) + '\nthread before\n')
        self.review.refresh()
        self.review.begin_iteration('first', 'First edit')
        self.write('Interactor.swift', (self.root / 'Interactor.swift').read_text().replace('thread before', 'thread after'))
        self.review.finish_iteration('first', 'First done', 'fix(test): first', 'First interaction')
        self.write('Interactor.swift', (self.root / 'Interactor.swift').read_text().replace('dependency before', 'dependency after'))
        self.write('OtherDependency.swift', 'another imported dependency\n')
        self.review.refresh()
        self.review.begin_iteration('second', 'Second edit')
        self.write('Own.swift', 'own file\n')
        self.review.refresh()
        files, blobs, _, _ = self.review.view('thread')
        self.assertEqual({f['path'] for f in files}, {'Interactor.swift', 'Own.swift'})
        file = next(f for f in files if f['path'] == 'Interactor.swift')
        self.assertTrue(blobs[file['id']]['old'].startswith(b'dependency after'))
        self.assertTrue(blobs[file['id']]['new'].startswith(b'dependency after'))
        self.assertIn('-thread before', file['patch'])
        self.assertIn('+thread after', file['patch'])
        self.assertEqual({f['path'] for f in self.review.files}, {'Interactor.swift', 'Own.swift', 'Dependency.swift', 'OtherDependency.swift'})
        self.assertEqual(self.git('diff', '--cached'), '')
        self.review.record_review_time('a' * 36, 'thread', 1000)
        self.assertEqual(self.review.review_time()['byScope']['thread'], 1000)

    def test_thread_scope_rejects_missing_or_ambiguous_history(self):
        with self.assertRaisesRegex(ValueError, 'no recorded interaction baseline'):
            self.review.view('thread')
        self.review.begin_iteration('first', 'Change value')
        self.write('Interactor.swift', 'let value = 3\n')
        self.review.finish_iteration('first', 'Done', 'fix(test): change', 'Change value')
        self.write('Interactor.swift', 'overlapping external update\n')
        self.review.refresh()
        with self.assertRaisesRegex(ValueError, 'Cannot isolate'):
            self.review.view('thread')
        self.review.save_feedback('Tool feedback still works when isolation fails', iteration='thread')

    def test_thread_scope_uses_chat_identity_on_a_reused_branch(self):
        self.review.begin_iteration('first', 'First chat edit')
        self.write('First.swift', 'first chat\n')
        self.review.finish_iteration('first', 'Done', 'fix(test): first', 'First chat change')
        os.environ['CODEX_THREAD_ID'] = 'another-chat'
        self.review.refresh()
        self.review.begin_iteration('second', 'Second chat edit')
        self.write('Second.swift', 'second chat\n')
        self.review.refresh()
        self.assertEqual([f['path'] for f in self.review.view('thread')[0]], ['Second.swift'])

    def test_shared_registry_routes_reviews_and_restores_removed_worktrees(self):
        m.register_review(self.review)
        worktree = self.root / 'another-review'
        self.git('worktree', 'add', '-b', 'other-feature', str(worktree), 'main')
        (worktree / 'Interactor.swift').write_text('other branch\n')
        other = m.Review(worktree, 'main', auto_rank=False)
        other.begin_iteration('other', 'Other request')
        (worktree / 'Own.swift').write_text('other own edit\n')
        other.finish_iteration('other', 'Done', 'fix(test): other', 'Other change')
        m.register_review(other)
        def serve():
            server = m.ReviewServer(('127.0.0.1', 0), m.Handler)
            server.registry = m.ReviewRegistry(self.review.store)
            server.token, server.version, server.assets = 'stable-token', 'test-version', {}
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            return server
        server = serve()
        def request(server, session_id, path='state', body=None):
            url = f'http://127.0.0.1:{server.server_port}/api/{path}?review={session_id}'
            with urllib.request.urlopen(urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                    headers={'X-Review-Token': 'stable-token', 'Content-Type': 'application/json'})) as response:
                return json.load(response)
        self.assertEqual(request(server, self.review.session_id)['branch'], 'feature')
        self.assertEqual(request(server, other.session_id)['branch'], 'other-feature')
        request(server, other.session_id, 'feedback', {'text': 'Tool feedback without a selected file'})
        self.git('worktree', 'remove', '--force', str(worktree))
        # A new registry represents a server restart; no old in-memory review is reused.
        restarted = serve()
        state = request(restarted, other.session_id)
        self.assertEqual(state['branch'], 'other-feature')
        self.assertFalse(state['canMerge'])
        self.assertEqual({f['path'] for f in state['files']}, {'Interactor.swift', 'Own.swift'})
        state = request(restarted, other.session_id + '&iteration=thread')
        self.assertEqual([f['path'] for f in state['files']], ['Own.swift'])
        self.assertEqual(request(restarted, self.review.session_id)['branch'], 'feature')
        with self.assertRaises(urllib.error.HTTPError):
            request(restarted, '../outside')

    def test_server_binds_without_resolving_the_host_name(self):
        # HTTPServer's default bind runs a reverse DNS lookup that hung CI runners.
        with patch.object(socket, 'getfqdn', side_effect=AssertionError('reverse DNS lookup')):
            server = m.ReviewServer(('127.0.0.1', 0), m.Handler)
        self.addCleanup(server.server_close)
        self.assertEqual((server.server_name, server.server_port), ('127.0.0.1', server.server_address[1]))

    def test_shared_launcher_reuses_port_token_and_review_identity_after_restart(self):
        probe = m.ReviewServer(('127.0.0.1', 0), m.Handler)
        origin = f'http://127.0.0.1:{probe.server_port}/'
        probe.server_close()
        metadata = self.review.store / 'shared-server.json'
        m.write_json(metadata, {'url': origin + '#persisted-token'})
        def stop():
            saved = m.read_json(metadata, {})
            if saved.get('pid') and m.process_alive(saved['pid']):
                os.kill(saved['pid'], 15)
        self.addCleanup(stop)
        def launch(repo):
            # Launching never opens a browser, so the user opens the printed URL manually.
            result = run_launcher([sys.executable, str(Path(m.__file__)), '--repo', str(repo)], self.review.store)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()
        first = launch(self.root)
        self.assertEqual(first, origin + '?review=' + self.review.session_id + '#persisted-token')
        runtime = self.review.store / 'runtime' / m.read_json(metadata, {})['version']
        for name in ('server.py', 'agent.py'):
            self.assertEqual((runtime / name).read_bytes(), (m.ASSETS / name).read_bytes())
        worktree = self.root / 'second-review'
        self.git('worktree', 'add', '-b', 'second-feature', str(worktree), 'main')
        second = launch(worktree)
        self.assertTrue(second.startswith(origin + '?review='))
        self.assertNotEqual(first, second)
        self.assertTrue(second.endswith('#persisted-token'))
        stop()
        time.sleep(.2)
        self.assertEqual(launch(self.root), first)
        with urllib.request.urlopen(urllib.request.Request(origin + 'api/state?' + second.split('?', 1)[1].split('#')[0],
                headers={'X-Review-Token': 'persisted-token'})) as response:
            self.assertEqual(json.load(response)['branch'], 'second-feature')

    def test_shared_registry_imports_existing_queue_snapshot(self):
        self.review.request_merge(self.review.approval_revision(), 'fix(test): approval', 'Existing queue snapshot')
        restored = m.ReviewRegistry(self.review.store).get(self.review.session_id)
        self.assertEqual(restored.branch, 'feature')
        self.assertEqual(restored.file_lines(restored.files[0]['id'])['new'], ['let value = 2'])

    def test_legacy_launcher_cannot_replace_the_upgraded_running_server(self):
        metadata = self.review.store / 'shared-server.json'
        legacy_assets = self.review.common / 'legacy-review-tool'
        for name in ('server.py', 'agent.py', *m.WEB_ASSETS):
            destination = legacy_assets / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((m.ASSETS / name).read_bytes())
        source = (legacy_assets / 'server.py').read_text()
        (legacy_assets / 'server.py').write_text(source.replace(
            "running.get('runtimeVersion', running['version']) != version", "running['version'] != version"))
        probe = m.ReviewServer(('127.0.0.1', 0), m.Handler)
        origin = f'http://127.0.0.1:{probe.server_port}/'
        probe.server_close()
        m.write_json(metadata, {'url': origin + '#persisted-token'})
        def stop():
            saved = m.read_json(metadata, {})
            if saved.get('pid') and m.process_alive(saved['pid']):
                os.kill(saved['pid'], 15)
        self.addCleanup(stop)
        def launch(script):
            result = run_launcher([sys.executable, str(script), '--repo', str(self.root), '--no-open'], self.review.store)
            self.assertEqual(result.returncode, 0, result.stderr)
        launch(legacy_assets / 'server.py')
        legacy = m.read_json(metadata, {})
        launch(Path(m.__file__))
        upgraded = m.read_json(metadata, {})
        self.assertNotEqual(upgraded['version'], legacy['version'])
        self.assertNotEqual(upgraded['pid'], legacy['pid'])
        launch(legacy_assets / 'server.py')
        self.assertEqual(m.read_json(metadata, {}), upgraded)
        with urllib.request.urlopen(urllib.request.Request(origin + 'api/health',
                headers={'X-Review-Token': 'persisted-token'})) as response:
            health = json.load(response)
        self.assertEqual(health['version'], legacy['version'])
        self.assertEqual(health['runtimeVersion'], upgraded['version'])

    def test_older_release_launcher_reuses_the_newer_running_server(self):
        metadata = self.review.store / 'shared-server.json'
        def copy_tool(name, release):
            assets = self.review.common / name
            for asset in ('server.py', 'agent.py', *m.WEB_ASSETS):
                destination = assets / asset
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((m.ASSETS / asset).read_bytes())
            source = (assets / 'server.py').read_text()
            (assets / 'server.py').write_text(source.replace(f"RELEASE = '{m.RELEASE}'", f"RELEASE = '{release}'"))
            return assets / 'server.py'
        older = copy_tool('older-review-tool', '0.0.1')
        same_release = copy_tool('edited-review-tool', m.RELEASE)
        (same_release.parent / 'agent.py').write_text((m.ASSETS / 'agent.py').read_text() + '\n# local edit\n')
        probe = m.ReviewServer(('127.0.0.1', 0), m.Handler)
        origin = f'http://127.0.0.1:{probe.server_port}/'
        probe.server_close()
        m.write_json(metadata, {'url': origin + '#persisted-token'})
        def stop():
            saved = m.read_json(metadata, {})
            if saved.get('pid') and m.process_alive(saved['pid']):
                os.kill(saved['pid'], 15)
        self.addCleanup(stop)
        def launch(script):
            result = run_launcher([sys.executable, str(script), '--repo', str(self.root), '--no-open'], self.review.store)
            self.assertEqual(result.returncode, 0, result.stderr)
            return m.read_json(metadata, {})
        downgraded = launch(older)
        current = launch(Path(m.__file__))
        self.assertNotEqual(current['pid'], downgraded['pid'])
        self.assertEqual(launch(older), current)
        with urllib.request.urlopen(urllib.request.Request(origin + 'api/health',
                headers={'X-Review-Token': 'persisted-token'})) as response:
            self.assertEqual(json.load(response)['release'], m.RELEASE)
        edited = launch(same_release)
        self.assertNotEqual(edited['pid'], current['pid'])

    def test_release_ordering_is_numeric_and_ignores_missing_releases(self):
        major, minor, patch = map(int, m.RELEASE.split('.'))
        self.assertTrue(m.newer_release(f'{major}.{minor + 10}.0'))
        self.assertTrue(m.newer_release(f'{major}.{minor}.{patch + 1}'))
        self.assertFalse(m.newer_release(m.RELEASE))
        self.assertFalse(m.newer_release('0.0.1'))
        for release in (None, '', 'next', 7):
            self.assertFalse(m.newer_release(release))

    def test_feedback_can_be_marked_implemented_and_reopened(self):
        first = self.review.save_feedback('Expand context')['entries'][0]
        self.review.save_feedback('Jump to definition')
        self.assertEqual({entry['status'] for entry in self.review.feedback()['entries']}, {'open'})
        inbox = self.review.set_feedback_status(first['id'], True)
        entry = next(e for e in inbox['entries'] if e['id'] == first['id'])
        self.assertEqual((entry['status'], entry['implementedBranch'], entry['text']), ('implemented', 'feature', 'Expand context'))
        self.assertIn('implementedAt', entry)
        # Status lives in the shared inbox, so another checkout sees it.
        self.assertEqual(next(e for e in m.Review(self.root, 'main', auto_rank=False).feedback()['entries'] if e['id'] == first['id'])['status'], 'implemented')
        entry = next(e for e in self.review.set_feedback_status(first['id'], False)['entries'] if e['id'] == first['id'])
        self.assertEqual(entry['status'], 'open')
        self.assertNotIn('implementedAt', entry)
        for bad_id, implemented in (('../settings', True), ('0' * 32, True), (first['id'], 'yes'), (None, True)):
            with self.assertRaises(ValueError):
                self.review.set_feedback_status(bad_id, implemented)

    def test_swift_definitions_index_worktree_types(self):
        self.write('Sources/Models.swift', 'import Foundation\n\n@MainActor public final class Store {\n    class func make() {}\n    enum State { case idle }\n}\nprotocol Loading {}\ntypealias Handler = () -> Void\n')
        self.write('Sources/Draft.swift', 'struct Draft {}\nextension Store {}\n')
        self.write('.gitignore', 'Derived/\n')
        self.write('Derived/Generated.swift', 'struct Generated {}\n')
        self.review.refresh()
        index = self.review.definition_index()
        self.assertEqual(index['Store'], [{'path': 'Sources/Models.swift', 'line': 3, 'kind': 'class'}])
        self.assertEqual(index['State'][0]['kind'], 'enum')
        self.assertEqual(index['Draft'], [{'path': 'Sources/Draft.swift', 'line': 1, 'kind': 'struct'}])
        self.assertEqual({'Loading', 'Handler'} <= set(index), True)
        self.assertNotIn('Generated', index)
        self.assertNotIn('func', index)
        self.assertEqual(self.review.definition('Missing')['locations'], [])
        with self.assertRaises(ValueError):
            self.review.definition('lowercase')
        self.assertEqual(self.review.source('Sources/Draft.swift')['lines'], ['struct Draft {}', 'extension Store {}'])
        for path in ('Derived/Generated.swift', '../outside.swift', '/etc/hosts', 'Sources', 'Missing.swift', 'Sources/*.swift'):
            with self.assertRaises(ValueError, msg=path):
                self.review.source(path)

    def test_code_search_covers_changed_files_or_the_whole_project(self):
        self.git('checkout', 'main')
        self.write('Old.swift', 'let removedNeedle = 1\nlet kept = 2\n')
        self.write('Untouched.swift', 'let Needle = 3\n')
        self.write('Far.swift', 'let farNeedle = 0\n' + ''.join(f'let line{n} = {n}\n' for n in range(2, 21)))
        self.git('add', '.')
        self.git('commit', '-m', 'feat(test): search fixtures')
        self.git('checkout', 'feature')
        self.git('merge', 'main')
        self.write('Old.swift', 'let kept = 2\nlet addedNeedle = 4\n')
        self.write('New.swift', 'let needle = 5\n')
        self.write('Far.swift', 'let farNeedle = 0\n' + ''.join(f'let line{n} = {n if n != 20 else 0}\n' for n in range(2, 21)))
        self.review.refresh()
        diff = self.review.search('needle')
        self.assertEqual([(r['path'], r['side'], r['line']) for r in diff['results']],
                         [('New.swift', 'new', 1), ('Old.swift', 'old', 1), ('Old.swift', 'new', 2)])
        self.assertEqual(diff['results'][0]['file'], next(f['id'] for f in self.review.files if f['path'] == 'New.swift'))
        self.assertEqual([r['line'] for r in self.review.search('line16')['results']], [16])
        self.assertEqual([r['path'] for r in self.review.search('needle', match_case=True)['results']], ['New.swift'])
        files = self.review.search('needle', 'files')
        self.assertEqual([(r['path'], r['side'], r['line']) for r in files['results']],
                         [('Far.swift', 'new', 1), ('New.swift', 'new', 1), ('Old.swift', 'new', 2), ('Old.swift', 'old', 1)])
        project = self.review.search('needle', 'project')
        self.assertEqual({(r['path'], r['line']) for r in project['results']}, {('Far.swift', 1), ('New.swift', 1), ('Old.swift', 2), ('Untouched.swift', 1)})
        self.assertNotIn('file', project['results'][0])
        self.assertEqual([r['path'] for r in self.review.search('Needle', 'project', match_case=True)['results']], ['Far.swift', 'Old.swift', 'Untouched.swift'])
        self.assertFalse(project['truncated'])
        self.write('Many.swift', 'needle\n' * (m.MAX_SEARCH_RESULTS + 5))
        self.review.refresh()
        many = self.review.search('needle', 'project')
        self.assertEqual((len(many['results']), many['truncated']), (m.MAX_SEARCH_RESULTS, True))
        for query, scope in (('', 'files'), ('a\nb', 'diff'), ('x' * 201, 'diff'), ('needle', 'everywhere'), (None, 'diff')):
            with self.assertRaises(ValueError, msg=(query, scope)):
                self.review.search(query, scope)

    def test_recreated_worktree_with_a_merged_branch_name_starts_a_fresh_review(self):
        path = self.root.resolve() / 'topic-worktree'
        self.git('worktree', 'add', '-b', 'topic', str(path), 'main')
        first = m.Review(path, 'main', auto_rank=False)
        legacy = m.digest((str(path) + 'topic' + 'main').encode())[:24]
        self.assertNotEqual(first.session_id, legacy)
        m.write_json(first.store / f'{first.session_id}-merge-request.json', {'id': 'old', 'status': 'merged', 'requestedAt': '2020-01-01T00:00:00+00:00'})
        first.session['comments'].append({'id': 'c', 'text': 'Old comment'})
        first.save_session()
        self.git('worktree', 'remove', '--force', str(path))
        self.git('branch', '-D', 'topic')
        time.sleep(0.05)
        self.git('worktree', 'add', '-b', 'topic', str(path), 'main')
        second = m.Review(path, 'main', auto_rank=False)
        self.assertNotEqual(second.session_id, first.session_id)
        self.assertIsNone(second.merge_request())
        self.assertEqual(second.session['comments'], [])
        self.assertEqual(m.Review(path, 'main', auto_rank=False).session_id, second.session_id)
        self.assertEqual(self.review.session_id, m.digest((str(self.root.resolve()) + 'feature' + 'main').encode())[:24])

    def test_legacy_review_identity_is_kept_unless_it_predates_the_worktree(self):
        path = self.root.resolve() / 'legacy-worktree'
        self.git('worktree', 'add', '-b', 'legacy', str(path), 'main')
        store = self.review.store
        legacy = m.digest((str(path) + 'legacy' + 'main').encode())[:24]
        now = m.datetime.now(m.timezone.utc).isoformat()
        m.write_json(store / 'reviews' / f'{legacy}.json', {'sessionId': legacy})
        self.assertEqual(m.Review(path, 'main', auto_rank=False).session_id, legacy)
        m.write_json(store / f'{legacy}.json', {'comments': [{'id': 'c'}], 'viewed': {}, 'iterations': [{'id': 'current', 'number': 1, 'finishedAt': now}]})
        self.assertEqual(m.Review(path, 'main', auto_rank=False).session_id, legacy)
        m.write_json(store / f'{legacy}.json', {'comments': [{'id': 'old'}], 'viewed': {'x': 'y'}, 'mergeDraft': {'title': 'feat(x): now', 'description': 'Now'},
                                                 'iterations': [{'id': 'old', 'number': 1, 'finishedAt': '2020-01-01T00:00:00+00:00'}, {'id': 'current', 'number': 2, 'finishedAt': now}],
                                                 'pendingIteration': {'id': 'next', 'request': 'Next'}, 'agent': {'provider': 'claude', 'sessionId': 's'}})
        m.write_json(store / f'{legacy}-merge-request.json', {'id': 'old', 'status': 'merged', 'requestedAt': '2020-01-01T00:00:00+00:00'})
        review = m.Review(path, 'main', auto_rank=False)
        self.assertNotEqual(review.session_id, legacy)
        self.assertIsNone(review.merge_request())
        self.assertEqual([(i['id'], i['number']) for i in review.session['iterations']], [('current', 1)])
        self.assertEqual((review.session['pendingIteration']['id'], review.session['comments'], review.session['viewed']), ('next', [], {}))
        self.assertEqual(review.session['mergeDraft']['title'], 'feat(x): now')

    def test_recreated_worktree_drops_the_previous_worktrees_pending_interaction(self):
        path = self.root.resolve() / 'pending-worktree'
        self.git('worktree', 'add', '-b', 'pending', str(path), 'main')
        store = self.review.store
        legacy = m.digest((str(path) + 'pending' + 'main').encode())[:24]
        old = {'comments': [], 'viewed': {}, 'mergeDraft': {'title': 'feat(x): old', 'description': 'Old'},
               'iterations': [{'id': 'old', 'number': 1, 'finishedAt': '2020-01-01T00:00:00+00:00'}], 'agent': {'provider': 'claude', 'sessionId': 'old-chat'}}
        m.write_json(store / f'{legacy}-merge-request.json', {'id': 'old', 'status': 'merged', 'requestedAt': '2020-01-01T00:00:00+00:00'})
        for pending in ({'id': 'stale', 'request': 'Old'}, {'id': 'stale', 'request': 'Old', 'startedAt': '2020-01-02T00:00:00+00:00'}):
            m.write_json(store / f'{legacy}.json', {**old, 'pendingIteration': pending})
            review = m.Review(path, 'main', auto_rank=False)
            self.assertNotEqual(review.session_id, legacy)
            self.assertNotIn('pendingIteration', review.session)
            self.assertEqual(review.session['iterations'], [])
        review.begin_iteration('fresh', 'New request')
        self.assertEqual(review.session['pendingIteration']['id'], 'fresh')
        self.assertFalse(m.datetime.fromisoformat(review.session['pendingIteration']['startedAt']) < review.worktree_created())
        self.assertEqual(m.read_json(store / f'{legacy}.json', {})['pendingIteration']['id'], 'stale')
        (store / f'{review.session_id}.json').unlink()
        started = m.datetime.now(m.timezone.utc).isoformat()
        m.write_json(store / f'{legacy}.json', {**old, 'pendingIteration': {'id': 'current', 'request': 'Now', 'startedAt': started}})
        review = m.Review(path, 'main', auto_rank=False)
        self.assertEqual((review.session['pendingIteration']['id'], review.session['iterations']), ('current', []))

    def test_callers_list_call_sites_without_declarations_or_comments(self):
        self.write('Sources/Loader.swift', 'final class Loader {\n    func load(id: Int) {}\n    func reload() { load(id: 1) }\n}\n')
        self.write('Sources/Screen.swift', 'let loader = Loader()\n// load(id: 0) is not a call\nloader.load (id: 2)\nloader.load { }\npreload(id: 3)\n')
        self.write('Sources/Notes.md', 'load(id: 4)\n')
        self.review.refresh()
        result = self.review.callers('load')
        self.assertEqual([(r['path'], r['line']) for r in result['results']],
                         [('Sources/Loader.swift', 3), ('Sources/Screen.swift', 3), ('Sources/Screen.swift', 4)])
        self.assertEqual(result['results'][0]['text'], 'func reload() { load(id: 1) }')
        for name in ('', '1load', 'load(', 'a' * 202, None):
            with self.assertRaises(ValueError, msg=name):
                self.review.callers(name)

    def test_expanded_context_lines_accept_comments(self):
        self.git('checkout', 'main')
        self.write('Long.swift', ''.join(f'let line{n} = {n}\n' for n in range(1, 41)))
        self.git('add', '.')
        self.git('commit', '-m', 'feat(test): long file')
        self.git('checkout', 'feature')
        self.git('merge', 'main')
        self.write('Long.swift', ''.join(f'let line{n} = {n if n != 20 else 0}\n' for n in range(1, 41)))
        self.review.refresh()
        file = next(f for f in self.review.files if f['path'] == 'Long.swift')
        self.assertNotIn(1, {row['new'] for row in file['rows']})
        lines = self.review.file_lines(file['id'])
        self.assertEqual((len(lines['old']), len(lines['new']), lines['new'][19]), (40, 40, 'let line20 = 0'))
        server = m.ReviewServer(('127.0.0.1', 0), m.Handler)
        server.review, server.token, server.assets = self.review, 'test-token', {}
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        def request(path, body=None):
            return urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{server.server_port}{path}', data=None if body is None else json.dumps(body).encode(), headers={'X-Review-Token': 'test-token', 'Content-Type': 'application/json'}))
        with request('/api/file?id=' + file['id']) as response:
            self.assertEqual((lambda data: (data['oldCount'], data['newCount']))(json.load(response)), (40, 40))
        with request('/api/comment', {'file': file['id'], 'fingerprint': file['fingerprint'], 'side': 'old', 'line': 1, 'endLine': 3, 'text': 'Expanded context'}) as response:
            self.assertEqual(json.load(response)['session']['comments'][-1]['endLine'], 3)
        with self.assertRaises(urllib.error.HTTPError) as error:
            request('/api/comment', {'file': file['id'], 'fingerprint': file['fingerprint'], 'side': 'new', 'line': 40, 'endLine': 41, 'text': 'Past the end'})
        self.assertEqual(error.exception.code, 400)
        error.exception.close()
        feedback = self.review.save_feedback('Mark me')['entries'][0]
        with request('/api/feedback/status', {'id': feedback['id'], 'implemented': True}) as response:
            self.assertEqual(json.load(response)['entries'][0]['status'], 'implemented')
        with request('/api/definition?name=Missing') as response:
            self.assertEqual(json.load(response), {'name': 'Missing', 'locations': []})
        with request('/api/source?path=Long.swift') as response:
            self.assertEqual(len(json.load(response)['lines']), 40)

    def test_thread_title_follows_the_latest_agent_title_record(self):
        state = self.review.state()
        self.assertIsNone(state['threadTitle'])
        index = self.homes / 'codex' / 'session_index.jsonl'
        index.parent.mkdir(parents=True)
        index.write_text(json.dumps({'id': 'original-codex-chat', 'thread_name': 'Add review titles'}) + '\n'
                         + json.dumps({'id': 'other-chat', 'thread_name': 'Unrelated'}) + '\n')
        self.assertEqual(self.review.state()['threadTitle'], 'Add review titles')
        with index.open('a') as file:
            file.write(json.dumps({'id': 'original-codex-chat', 'thread_name': 'Renamed thread'}) + '\n{"id": "original-codex-chat", "thread_na')
        self.assertEqual(self.review.state()['threadTitle'], 'Renamed thread')
        with index.open('a') as file:
            file.write('me": "Completed later"}\n')
        self.assertEqual(self.review.state()['threadTitle'], 'Completed later')

        os.environ.update(CLAUDECODE='1', CLAUDE_CODE_SESSION_ID='claude-session-1')
        self.review.record_agent()
        log = self.homes / 'claude' / 'projects' / '-repo' / 'claude-session-1.jsonl'
        log.parent.mkdir(parents=True)
        log.write_text(json.dumps({'type': 'user', 'message': 'custom-title'}) + '\n'
                       + json.dumps({'type': 'custom-title', 'customTitle': 'Claude thread', 'sessionId': 'claude-session-1'}) + '\n')
        self.assertEqual(self.review.state()['threadTitle'], 'Claude thread')
        log.unlink()
        self.review.session['mergeDraft'] = {'title': 'feat(review): fallback title', 'description': 'd'}
        self.assertEqual(self.review.state()['threadTitle'], 'feat(review): fallback title')

    def test_settings_validate_types(self):
        for override in [{'imageScale': 500}, {'hideTests': 'true'}, {'hideManifests': 1}, {'exclude': [4]}, {'rubric': ''}, {'diffMode': 'sideways'}, {'diffMode': None}]:
            with self.assertRaises(ValueError):
                self.review.update_settings({**m.DEFAULTS, **override})

    def test_diff_mode_is_shared_across_reviews_without_overwriting_other_defaults(self):
        worktree = self.root / 'other-review'
        self.git('worktree', 'add', '-b', 'other-review', str(worktree), 'main')
        other = m.Review(worktree, 'main', auto_rank=False)
        self.review.update_settings({'imageScale': 60})
        other.update_settings({'diffMode': 'unified'})
        self.assertEqual(self.review.state()['settings']['diffMode'], 'unified')
        self.assertEqual(other.settings['imageScale'], 60)
        restarted = m.Review(worktree, 'main', auto_rank=False)
        self.assertEqual(restarted.settings['diffMode'], 'unified')
        self.review.update_settings({'hideTests': False})
        self.assertEqual(other.state()['settings']['diffMode'], 'unified')
        with self.assertRaises(ValueError):
            self.review.update_settings({'unknown': True})
        self.assertEqual(m.read_json(self.review.store / 'settings.json', {})['diffMode'], 'unified')

    def test_interactions_are_immutable_and_do_not_change_head_or_index(self):
        self.git('add', 'Interactor.swift')
        self.write('Interactor.swift', 'let value = 3\n')
        head, staged = self.git('rev-parse', 'HEAD'), self.git('diff', '--cached')
        self.review.begin_iteration('user-1', 'Change the business calculation')
        self.review.begin_iteration('user-1', 'Internal retry must not add an iteration')
        self.write('Interactor.swift', 'let value = 4\n')
        self.write('new.txt', 'new file\n')
        self.review.finish_iteration('user-1', 'Changed calculation and added data', 'feat(test): update calculation', 'Update calculation and add data.\n\nValidation: tests.')
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual(self.git('diff', '--cached'), staged)
        iteration = self.review.session['iterations'][0]
        self.assertEqual(self.git('show', iteration['before'] + ':Interactor.swift'), 'let value = 3')
        files, blobs, _, _ = self.review.view('user-1')
        file = next(f for f in files if f['path'] == 'Interactor.swift')
        self.assertEqual(blobs[file['id']]['old'], b'let value = 3\n')
        self.assertEqual(blobs[file['id']]['new'], b'let value = 4\n')
        self.write('Interactor.swift', 'let value = 99\n')
        self.review.refresh()
        self.assertEqual(self.review.view('user-1')[1][file['id']]['new'], b'let value = 4\n')
        self.review.finish_iteration('user-1', 'Completed same user turn after verification', 'feat(test): update calculation', 'Final change and tests.')
        self.assertEqual(len(self.review.session['iterations']), 1)
        self.assertEqual(self.review.view('user-1')[1][file['id']]['new'], b'let value = 99\n')

    def test_cli_iterations_and_browser_comments_do_not_overwrite_each_other(self):
        browser = m.Review(self.root, 'main', auto_rank=False)
        self.review.begin_iteration('one', 'Change calculation')
        browser.session['comments'].append({'id': 'browser-comment', 'resolved': False})
        browser.save_session()
        self.write('Interactor.swift', 'let value = 3\n')
        self.review.finish_iteration('one', 'Changed', 'fix(test): calculation', 'Change calculation. Tests pass.')
        saved = m.read_json(self.review.store / f'{self.review.session_id}.json', {})
        self.assertEqual(saved['comments'][0]['id'], 'browser-comment')
        self.assertEqual(len(saved['iterations']), 1)
        self.assertNotIn('pendingIteration', saved)
        browser.session['viewed']['file'] = 'fingerprint'
        browser.save_session()
        saved = m.read_json(self.review.store / f'{self.review.session_id}.json', {})
        self.assertEqual(len(saved['iterations']), 1)
        self.assertEqual(saved['mergeDraft']['title'], 'fix(test): calculation')
        self.assertNotIn('pendingIteration', saved)

    def test_iteration_boundaries_and_historical_deletions(self):
        with self.assertRaisesRegex(ValueError, 'baseline'):
            self.review.finish_iteration('missing', 'Done', 'fix(test): change', 'Change and tests.')
        self.review.begin_iteration('one', 'Add a file')
        with self.assertRaisesRegex(ValueError, 'pending'):
            self.review.begin_iteration('two', 'Internal tool step')
        self.write('added.txt', 'first version\n')
        self.review.finish_iteration('one', 'Added file', 'feat(test): add file', 'Add file. Tests pass.')
        self.review.begin_iteration('two', 'Remove the file')
        (self.root / 'added.txt').unlink()
        self.review.finish_iteration('two', 'Removed file', 'fix(test): remove file', 'Remove obsolete file. Tests pass.')
        removed = self.review.view('two')[0][0]
        self.assertEqual((removed['path'], removed['status']), ('added.txt', 'D'))
        self.assertEqual(self.review.view('two')[1][removed['id']]['old'], b'first version\n')
        self.review.begin_iteration('three', 'Re-add the file')
        self.write('added.txt', 'second version\n')
        self.review.finish_iteration('three', 'Re-added file', 'fix(test): restore file', 'Restore file with updated behavior. Tests pass.')
        self.assertEqual(self.review.view('three')[1][removed['id']]['new'], b'second version\n')
        self.assertEqual(self.review.view('one')[1][removed['id']]['new'], b'first version\n')
        with self.assertRaisesRegex(ValueError, 'Unknown'):
            self.review.state('../../outside')
        with self.assertRaises(ValueError):
            self.review.begin_iteration('../../outside', 'Bad ID')

    def simulator_metadata(self, udid='063F4A18-E330-4371-910E-D104A89F189B'):
        self.write('.worktree-simulator/simulator.env', f'WORKTREE_SIMULATOR_UDID={udid}\nWORKTREE_SIMULATOR_NAME=App\\ feature\n')
        return udid

    def test_simulator_metadata_is_local_validated_and_unavailable_after_cleanup(self):
        with patch.object(m.sys, 'platform', 'darwin'):
            self.assertIsNone(self.review.simulator())
            udid = self.simulator_metadata()
            with patch.dict(os.environ, {'WORKTREE_SIMULATOR_UDID': 'inherited-wrong-device'}):
                self.assertEqual(self.review.simulator(), {'id': udid, 'name': 'App feature', 'url': 'devices:///manage/select?id=' + udid})
            for invalid in ['$(touch /tmp/unsafe)', 'bad-id', '\"unterminated']:
                self.simulator_metadata(invalid)
                self.assertIsNone(self.review.simulator())
            (self.root / '.worktree-simulator/simulator.env').unlink()
            self.assertIsNone(self.review.simulator())
        with patch.object(m.sys, 'platform', 'linux'):
            self.simulator_metadata()
            self.assertIsNone(self.review.simulator())

    def test_open_simulator_boots_exact_device_and_uses_native_deep_link(self):
        udid = self.simulator_metadata()
        other = {'udid': '11111111-2222-3333-4444-555555555555', 'state': 'Shutdown', 'isAvailable': True}
        listed = {'devices': {'iOS': [other, {'udid': udid, 'state': 'Shutdown', 'isAvailable': True}]}}
        def result(value):
            return subprocess.CompletedProcess([], 0, json.dumps(value) if value is not None else '', '')
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'run', side_effect=[result(listed), result(None), result(None)]) as run:
            self.assertEqual(self.review.open_simulator()['id'], udid)
            self.assertEqual(run.call_args_list[1].args[0], ['xcrun', 'simctl', 'boot', udid])
            self.assertEqual(run.call_args_list[2].args[0], ['/usr/bin/open', 'devices:///manage/select?id=' + udid])
        listed['devices']['iOS'][1]['state'] = 'Booted'
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'run', side_effect=[result(listed), result(None)]) as run:
            self.review.open_simulator()
            self.assertEqual(run.call_count, 2, 'Opening an already booted device must be repeatable')
        unavailable = {'devices': {'iOS': [{'udid': udid, 'state': 'Shutdown', 'isAvailable': False}]}}
        for output in [subprocess.CompletedProcess([], 1, '', 'Simulator service unavailable'), result({'devices': {}}), result(unavailable), result(None)]:
            with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'run', return_value=output) as run:
                with self.assertRaises(ValueError):
                    self.review.open_simulator()
                self.assertEqual(run.call_count, 1, 'Failure must never open a different device')
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'run', side_effect=[result(listed), subprocess.CompletedProcess([], 1, '', 'No URL handler')]):
            with self.assertRaisesRegex(ValueError, 'No URL handler'):
                self.review.open_simulator()

    def write_movie(self, name, seconds=2, **options):
        path = self.homes / name
        path.write_bytes(movie(seconds, **options))
        return path

    def test_movie_duration_reads_finished_headers_and_rejects_unfinished_recordings(self):
        self.assertEqual(m.movie_duration(self.write_movie('short.mov', 12.5)), 12.5)
        self.assertEqual(m.movie_duration(self.write_movie('long.mp4', 3, long=True, timescale=90000)), 3)
        complete = movie(5)
        for name, data in [('unfinished.mov', complete[:28]), ('truncated.mov', complete[:-20]), ('text.mov', b'not a movie at all')]:
            (self.homes / name).write_bytes(data)
            self.assertIsNone(m.movie_duration(self.homes / name), name)

    def test_demos_attach_to_the_current_interaction_and_follow_review_scopes(self):
        self.review.begin_iteration('one', 'Add a reorder button')
        source = self.write_movie('reorder.mov', 7.5)
        first = self.review.add_demo('  Reorder from history  ', source)
        self.assertEqual((first['title'], first['iteration'], first['source'], first['durationSeconds']), ('Reorder from history', 'one', 'file', 7.5))
        stored = self.review.store / 'demos' / self.review.session_id / first['file']
        self.assertEqual(stored.read_bytes(), source.read_bytes())
        self.assertTrue(source.exists(), 'Attaching a file copies it')
        self.assertTrue(stored.is_relative_to(Path(self.git('rev-parse', '--path-format=absolute', '--git-common-dir'))), 'Demos stay outside the diff')
        self.review.finish_iteration('one', 'Added', 'feat(test): reorder', 'Reorder')
        self.review.begin_iteration('two', 'Handle a failed reorder')
        second = self.review.add_demo('Reorder fails offline', self.write_movie('failure.mp4', 3))
        self.review.finish_iteration('two', 'Handled', 'feat(test): reorder', 'Reorder')
        outside = self.review.add_demo('Outside an interaction', self.write_movie('outside.m4v'))
        self.assertIsNone(outside['iteration'], 'A demo outside an interaction is never attributed to one')
        titles = lambda scope: [d['title'] for d in self.review.state(scope)['demos']['items']]
        self.assertEqual(titles(None), ['Reorder from history', 'Reorder fails offline', 'Outside an interaction'])
        self.assertEqual(titles('one'), ['Reorder from history'])
        self.assertEqual(titles('two'), ['Reorder fails offline'])
        self.assertEqual(titles('thread'), ['Reorder from history', 'Reorder fails offline'])
        self.assertEqual(self.review.state('two')['demos']['total'], 3)
        restarted = m.Review(self.root, 'main')
        self.assertEqual([d['id'] for d in restarted.saved_demos()], [first['id'], second['id'], outside['id']])
        self.assertTrue(all(d['available'] for d in restarted.state()['demos']['items']))
        for title, path in [('Notes', self.homes / 'notes.txt'), ('', source), ('Two\nlines', source),
                            ('Unfinished', self.homes / 'unfinished.mov'), ('Missing', self.homes / 'missing.mov')]:
            if path.name in ('notes.txt', 'unfinished.mov'):
                path.write_bytes(movie(1)[:28])
            with self.assertRaises(ValueError, msg=title):
                restarted.add_demo(title, path)
        self.assertEqual(len(restarted.saved_demos()), 3, 'Rejected movies are never kept')
        restarted.remove_demo(first['id'])
        self.assertFalse(stored.exists())
        self.assertEqual([d['id'] for d in restarted.saved_demos()], [second['id'], outside['id']])
        with self.assertRaisesRegex(ValueError, 'Unknown demo'):
            restarted.remove_demo(first['id'])

    def test_demo_reminder_follows_configured_ui_paths_and_the_agents_reason(self):
        self.write('App/Screen.swift', 'struct Screen {}\n')
        self.write('App/ScreenTests.swift', 'final class ScreenTests {}\n')
        self.review.refresh()
        self.assertEqual(self.review.demo_state()['uiPaths'], [], 'Without configured paths no demo is expected')
        self.assertIsNone(self.review.demo_reminder())
        self.write('.config/local-review.toml', "[demos]\npaths = ['^App/']\n")
        self.review.refresh()
        self.assertEqual(self.review.demo_state()['uiPaths'], ['App/Screen.swift'], 'Tests never require a demo')
        self.assertRegex(self.review.demo_reminder(), r'^1 changed file affects the app UI')
        self.review.skip_demo('Renames a private type; nothing on screen changes.')
        self.assertIsNone(self.review.demo_reminder())
        self.assertEqual(self.review.state()['demos']['skipped']['reason'], 'Renames a private type; nothing on screen changes.')
        with self.assertRaises(ValueError):
            self.review.skip_demo('   ')
        self.review.edit_session(lambda session: session.pop('demoSkipped'))
        self.review.add_demo('Screen appears', self.write_movie('screen.mov'))
        self.assertIsNone(self.review.demo_reminder())
        recording = {'title': 'Error state', 'startedAt': 'now', 'device': 'App feature', 'running': True}
        with patch.object(m.Review, 'demo_recording', return_value=recording):
            self.assertRegex(self.review.demo_reminder(), 'Error state" is still recording')

    def test_open_demos_plays_stored_files_in_quicktime_only(self):
        first = self.review.add_demo('Happy path', self.write_movie('happy.mov'))
        second = self.review.add_demo('Empty state', self.write_movie('empty.mp4'))
        directory = self.review.store / 'demos' / self.review.session_id
        real_run, opened = subprocess.run, []
        def run(args, **options):
            if args[0] != '/usr/bin/open':
                return real_run(args, **options)
            opened.append(args)
            return subprocess.CompletedProcess(args, 0, '', '')
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'run', side_effect=run):
            self.assertEqual(self.review.open_demos([first['id'], second['id'], first['id']]), {'opened': 2})
            self.assertEqual(opened, [['/usr/bin/open', '-a', 'QuickTime Player', str(directory / first['file']), str(directory / second['file'])]])
            for ids in [[], 'all', ['../outside'], [first['id'], 'unknown']]:
                with self.assertRaises(ValueError):
                    self.review.open_demos(ids)
            (directory / second['file']).unlink()
            with self.assertRaisesRegex(ValueError, 'missing'):
                self.review.open_demos([second['id']])
            self.assertFalse(self.review.state()['demos']['items'][1]['available'])
            self.assertEqual(len(opened), 1, 'Invalid requests never open anything')
            m.register_review(self.review)
            server = m.ReviewServer(('127.0.0.1', 0), m.Handler)
            server.registry = m.ReviewRegistry(self.review.store)
            server.token, server.version, server.assets = 'demo-token', 'test-version', {}
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            url = f'http://127.0.0.1:{server.server_port}/api/demos/open?review={self.review.session_id}'
            request = urllib.request.Request(url, data=json.dumps({'ids': [first['id']]}).encode(),
                                             headers={'X-Review-Token': 'demo-token', 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request) as response:
                self.assertEqual(json.load(response), {'opened': 1})
            self.assertEqual(opened[-1][-1], str(directory / first['file']))
        with patch.object(m.sys, 'platform', 'linux'), self.assertRaisesRegex(ValueError, 'macOS'):
            self.review.open_demos([first['id']])

    def fake_appearance(self, value):
        """Stands in for `simctl ui <udid> appearance [dark|light]` and records every change."""
        device = {'value': value, 'set': []}
        def simctl(review, *args):
            if args[0] != 'ui':
                raise AssertionError(f'Unexpected simctl call {args}')
            if len(args) == 4:
                device['set'].append(args[3])
                device['value'] = args[3]
            return device['value'] + '\n'
        stub = patch.object(m.Review, 'simctl', autospec=True, side_effect=simctl)
        stub.start()
        self.addCleanup(stub.stop)
        return device

    def test_simulator_recording_starts_on_the_worktree_device_and_attaches_on_stop(self):
        udid = self.simulator_metadata()
        simulator = {'id': udid, 'name': 'App feature', 'url': ''}
        real_popen, launched = subprocess.Popen, []
        def recorder(args, **options):
            if args[0] != 'xcrun':
                return real_popen(args, **options)  # subprocess.run uses Popen too
            launched.append(args)
            return real_popen([sys.executable, '-c', FAKE_RECORDER, *args[1:]], **options)
        self.review.begin_iteration('demo', 'Show the new screen')
        directory = self.review.store / 'demos' / self.review.session_id
        appearance = self.fake_appearance('light')
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'Popen', side_effect=recorder), \
                patch.object(m.Review, 'simulator_device', return_value=(simulator, {'state': 'Shutdown'})):
            with self.assertRaisesRegex(ValueError, 'not booted'):
                self.review.start_demo_recording('Open the screen')
            self.assertEqual(launched, [])
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'Popen', side_effect=recorder), \
                patch.object(m.Review, 'simulator_device', return_value=(simulator, {'state': 'Booted'})):
            recording = self.review.start_demo_recording('Open the screen')
            self.assertEqual(launched[0][:6], ['xcrun', 'simctl', 'io', udid, 'recordVideo', '--codec=h264'])
            self.addCleanup(lambda: m.process_alive(recording['pid']) and os.kill(recording['pid'], 9))
            self.assertEqual(self.review.state()['demos']['recording']['title'], 'Open the screen')
            with self.assertRaisesRegex(ValueError, 'still recording'):
                self.review.start_demo_recording('Another scenario')
            self.assertRegex(self.review.demo_reminder(), 'still recording')
            demo = m.Review(self.root, 'main').stop_demo_recording()
            self.assertFalse(m.process_alive(recording['pid']))
            self.assertEqual((demo['title'], demo['iteration'], demo['source'], demo['device'], demo['durationSeconds'], demo['appearance']),
                             ('Open the screen', 'demo', 'simulator', 'App feature', 4.25, 'dark'))
            self.assertEqual(appearance, {'value': 'light', 'set': ['dark', 'light']}, 'Recording defaults to dark and restores the device afterwards')
            self.assertEqual(sorted(p.name for p in directory.iterdir()), [demo['file']], 'Recorder files are cleaned up')
            self.assertIsNone(self.review.state()['demos']['recording'])
            with self.assertRaisesRegex(ValueError, 'No demo is recording'):
                self.review.stop_demo_recording()
        def failing(args, **options):
            if args[0] != 'xcrun':
                return real_popen(args, **options)
            return real_popen([sys.executable, '-c', 'import sys; sys.stderr.write("Invalid device state"); sys.exit(1)'], **options)
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'Popen', side_effect=failing), \
                patch.object(m.Review, 'simulator_device', return_value=(simulator, {'state': 'Booted'})):
            with self.assertRaisesRegex(ValueError, 'Invalid device state'):
                self.review.start_demo_recording('Broken recorder')
            self.assertFalse((directory / 'recording.json').exists())
        # A reused PID is never signalled, and a recording that never produced a movie is discarded.
        m.write_json(directory / 'recording.json', {'id': 'f' * 16, 'title': 'Lost', 'pid': os.getpid(),
                     'path': str(directory / 'recording-lost.mov'), 'log': str(directory / 'recording-lost.log'), 'iteration': None})
        self.assertFalse(self.review.demo_recording()['running'])
        with self.assertRaisesRegex(ValueError, 'without a movie'):
            self.review.stop_demo_recording()
        self.assertFalse((directory / 'recording.json').exists())
        self.assertEqual([d['title'] for d in self.review.saved_demos()], ['Open the screen'])

    def test_recording_appearance_follows_the_flag_then_config_and_rejects_others(self):
        simulator = {'id': self.simulator_metadata(), 'name': 'App feature', 'url': ''}
        self.assertEqual(self.review.config['demos']['appearance'], 'dark')
        self.write('.config/local-review.toml', "[demos]\nappearance = 'light'\n")
        self.assertEqual(m.load_config(self.root)['demos']['appearance'], 'light')
        for invalid in ["[demos]\nappearance = 'sepia'\n", "[demos]\nappearance = 1\n"]:
            self.write('.config/local-review.toml', invalid)
            with self.assertRaisesRegex(ValueError, 'dark or light'):
                m.load_config(self.root)
        self.write('.config/local-review.toml', "[demos]\nappearance = 'light'\n")
        review = m.Review(self.root, 'main')
        device = self.fake_appearance('light')
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.Review, 'simulator_device', return_value=(simulator, {'state': 'Booted'})), \
                patch.object(m.subprocess, 'Popen', side_effect=OSError('recorder not started')):
            for flag in [None, 'dark']:
                with self.assertRaisesRegex(OSError, 'recorder not started'):
                    review.start_demo_recording('Scenario', flag)
            with self.assertRaisesRegex(ValueError, 'dark or light'):
                review.start_demo_recording('Scenario', 'sepia')
        self.assertEqual(device, {'value': 'light', 'set': ['dark', 'light']},
                         'The configured appearance leaves a matching device alone, the flag overrides it, and a failed start restores it')
        device.update(value='unsupported', set=[])
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.Review, 'simulator_device', return_value=(simulator, {'state': 'Booted'})), \
                patch.object(m.subprocess, 'Popen', side_effect=OSError('recorder not started')):
            with self.assertRaisesRegex(OSError, 'recorder not started'):
                review.start_demo_recording('Scenario', 'dark')
        self.assertEqual(device['set'], [], 'Runtimes without an appearance setting still record')

    def serve(self, review=None):
        """A registry server on a free port for this test's review."""
        review = review or self.review
        m.register_review(review)
        server = m.ReviewServer(('127.0.0.1', 0), m.Handler)
        server.registry = m.ReviewRegistry(review.store)
        server.token, server.version, server.assets = 'test-token', 'test-version', {}
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def request(self, server, path, headers=None, data=None):
        request = urllib.request.Request(f'http://127.0.0.1:{server.server_port}{path}', data=data, headers=headers or {})
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, dict(response.headers), response.read()
        except urllib.error.HTTPError as error:
            with error:
                return error.code, dict(error.headers), error.read()

    def test_demo_movies_stream_by_signed_url_with_byte_ranges(self):
        self.review.add_demo('Happy path', self.write_movie('happy.mov'))
        server = self.serve()
        api = {'X-Review-Token': 'test-token'}
        status, _, body = self.request(server, f'/api/state?review={self.review.session_id}', api)
        demo = json.loads(body)['demos']['items'][0]
        stored = (self.review.store / 'demos' / self.review.session_id / demo['file']).read_bytes()
        self.assertRegex(demo['src'], rf'^/demo\?review={self.review.session_id}&id={demo["id"]}&key=[0-9a-f]{{32}}$')
        self.assertNotIn('test-token', demo['src'], 'The page token never appears in a media URL')
        status, headers, body = self.request(server, demo['src'])
        self.assertEqual((status, headers['Content-Type'], headers['Accept-Ranges'], body), (200, 'video/mp4', 'bytes', stored))
        for header, expected in [('bytes=0-9', stored[:10]), ('bytes=10-', stored[10:]), ('bytes=-8', stored[-8:]), (f'bytes=5-{len(stored) + 50}', stored[5:])]:
            status, headers, body = self.request(server, demo['src'], {'Range': header})
            self.assertEqual((status, body), (206, expected), header)
            self.assertTrue(headers['Content-Range'].endswith(f'/{len(stored)}'), header)
        for header in [f'bytes={len(stored)}-', 'bytes=9-2', 'bytes=-', 'items=0-1']:
            status, headers, _ = self.request(server, demo['src'], {'Range': header})
            self.assertEqual((status, headers['Content-Range']), (416, f'bytes */{len(stored)}'), header)
        other = m.Review(self.root, 'main')
        other.media_secret = b'another-server'
        self.assertNotEqual(other.demo_source(demo['id']), demo['src'], 'Keys depend on the serving token')
        forged = demo['src'][:-32] + '0' * 32
        for path, expected in [(forged, 403), (demo['src'].replace('&key=', '&ignored='), 403),
                               (demo['src'].replace(demo['id'], 'f' * 16), 403)]:
            self.assertEqual(self.request(server, path)[0], expected, path)
        unsigned = m.Review(self.root, 'main')
        self.assertIsNone(unsigned.state()['demos']['items'][0]['src'], 'Without a server there is nothing to play')
        (self.review.store / 'demos' / self.review.session_id / demo['file']).unlink()
        self.assertEqual(self.request(server, demo['src'])[0], 404)

    def configure_run(self, destinations, exit_code=0, sleep=0):
        """Points [run] at small Python scripts: one prints destinations, the other records its argument."""
        scripts = self.homes / 'run'
        scripts.mkdir(exist_ok=True)
        (scripts / 'list.py').write_text(f'import json; print(json.dumps({destinations!r}))\n')
        (scripts / 'launch.py').write_text(f'import sys, time\nprint("building for", sys.argv[1], flush=True)\ntime.sleep({sleep})\nsys.exit({exit_code})\n')
        self.write('.config/local-review.toml', '[run]\n' + f'destinations = ["{sys.executable}", "{scripts / "list.py"}"]\n'
                   + f'command = ["{sys.executable}", "{scripts / "launch.py"}", "{{destination}}"]\n')
        return m.Review(self.root, 'main')

    def wait_for_run(self, review, status):
        deadline = time.monotonic() + 10
        while review.state()['run']['last']['status'] != status:
            if time.monotonic() > deadline:
                raise AssertionError(f'Run never became {status}: {review.state()["run"]}')
            time.sleep(.05)
        return review.state()['run']['last']

    def test_run_is_off_until_configured_and_config_needs_both_commands(self):
        self.assertIsNone(self.review.state()['run'])
        with self.assertRaisesRegex(ValueError, 'not configured'):
            self.review.run_destinations()
        for invalid, message in [('[run]\ncommand = ["run", "{destination}"]\n', 'needs both'),
                                 ('[run]\ndestinations = ["list"]\ncommand = ["run"]\n', 'needs both'),
                                 ('[run]\ndestinations = "list"\ncommand = ["run", "{destination}"]\n', 'list of strings'),
                                 ('[run]\nscheme = "App"\n', 'Unknown setting')]:
            self.write('.config/local-review.toml', invalid)
            with self.assertRaisesRegex(ValueError, message, msg=invalid):
                m.load_config(self.root, strict=True)

    def test_run_lists_destinations_and_launches_only_a_listed_one(self):
        phone = {'id': '00008120-PHONE', 'name': 'My iPhone', 'kind': 'device', 'detail': 'iPhone 17 · iOS 27.0'}
        review = self.configure_run([phone, {'id': 'SIM-1', 'name': 'iPhone 17 Simulator', 'extra': True}])
        self.assertEqual(review.state()['run'], {'available': True, 'last': None})
        self.assertEqual(review.run_destinations(), [phone, {'id': 'SIM-1', 'name': 'iPhone 17 Simulator', 'kind': '', 'detail': ''}])
        for destination in ['UNLISTED', None, ['00008120-PHONE']]:
            with self.assertRaises(ValueError, msg=destination):
                review.start_run(destination)
        self.assertIsNone(review.state()['run']['last'], 'Rejected destinations never start anything')
        review.start_run('00008120-PHONE')
        last = self.wait_for_run(review, 'succeeded')
        self.assertEqual((last['destination'], last['exitCode']), (phone, 0))
        log = review.run_log().decode()
        self.assertIn('launch.py 00008120-PHONE\n', log.splitlines()[0] + '\n', 'The log starts with the command')
        self.assertIn('building for 00008120-PHONE', log)
        self.assertEqual(m.Review(self.root, 'main').state()['run']['last']['status'], 'succeeded', 'Run results outlive the server')

    def test_run_reports_failures_and_rejects_bad_destination_lists(self):
        review = self.configure_run([{'id': 'SIM-1', 'name': 'Simulator'}], exit_code=65)
        review.start_run('SIM-1')
        self.assertEqual(self.wait_for_run(review, 'failed')['exitCode'], 65)
        for listed in [{'id': 'SIM-1'}, [{'id': 'SIM-1'}], [{'id': '', 'name': 'Blank'}], 'not json']:
            review = self.configure_run(listed)
            if listed == 'not json':
                (self.homes / 'run' / 'list.py').write_text('print("Simulators:")\n')
            with self.assertRaises(ValueError, msg=listed):
                review.run_destinations()
        (self.homes / 'run' / 'list.py').write_text('import sys; sys.stderr.write("devicectl unavailable"); sys.exit(1)\n')
        with self.assertRaisesRegex(ValueError, 'devicectl unavailable'):
            review.run_destinations()

    def test_run_allows_one_build_at_a_time_and_cancel_stops_it(self):
        review = self.configure_run([{'id': 'SIM-1', 'name': 'Simulator'}], sleep=30)
        server = self.serve(review)
        api = {'X-Review-Token': 'test-token', 'Content-Type': 'application/json'}
        path = f'/api/run?review={review.session_id}'
        status, _, body = self.request(server, path, api, json.dumps({'destination': 'SIM-1'}).encode())
        self.assertEqual((status, json.loads(body)['run']['last']['status']), (200, 'running'))
        pid = m.read_json(review.run_paths()[0], {})['pid']
        self.addCleanup(lambda: m.process_alive(pid) and os.killpg(pid, 9))
        status, _, body = self.request(server, path, api, json.dumps({'destination': 'SIM-1'}).encode())
        self.assertEqual(status, 400)
        self.assertRegex(json.loads(body)['error'], 'still building for Simulator')
        status, _, body = self.request(server, f'/api/run/cancel?review={review.session_id}', api, b'{}')
        self.assertEqual(status, 200)
        self.assertEqual(self.wait_for_run(review, 'cancelled')['exitCode'], -15)
        self.assertFalse(m.process_alive(pid))
        with self.assertRaisesRegex(ValueError, 'Nothing is running'):
            review.cancel_run()
        # A run whose server restarted has no recorded exit status, and a reused PID never counts as it.
        m.write_json(review.run_paths()[0], {'id': 'lost', 'pid': os.getpid(), 'destination': {'id': 'SIM-1', 'name': 'Simulator'},
                                             'status': 'running', 'startedAt': 'earlier'})
        self.assertEqual(review.state()['run']['last']['status'], 'ended')
        review.start_run('SIM-1')
        self.addCleanup(lambda: m.process_alive(m.read_json(review.run_paths()[0], {})['pid']) and os.killpg(m.read_json(review.run_paths()[0], {})['pid'], 9))
        self.assertEqual(review.state()['run']['last']['status'], 'running')
        review.cancel_run()
        self.wait_for_run(review, 'cancelled')

    def test_browser_merge_saves_durable_approval_without_git_mutations(self):
        head, index = self.git('rev-parse', 'HEAD'), self.git('diff', '--cached')
        self.review.session['comments'].append({'id': 'review-comment', 'text': 'check does this work?', 'resolved': False})
        self.review.save_session()
        with patch.object(self.review, 'start_merge') as merge:
            request = self.review.request_merge(self.review.approval_revision(), '', '')
            duplicate = self.review.request_merge(self.review.approval_revision(), '', '')
            merge.assert_not_called()
        self.assertEqual(request['id'], duplicate['id'])
        self.notify.assert_called_once()
        self.assertEqual(request['status'], 'pending')
        self.assertEqual(request['comments'][0]['text'], 'check does this work?')
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual(self.git('diff', '--cached'), index)
        reopened = m.Review(self.root, 'main', auto_rank=False)
        self.assertEqual(reopened.merge_request()['id'], request['id'])
        self.assertEqual(reopened.state()['mergeRequest']['revision'], self.review.revision)

    def test_first_browser_approval_survives_main_advancing_and_server_refresh(self):
        reviewed = self.review.state()['merge']['revision']
        original = self.review.revision
        newer_main = self.git('commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-m', 'another worktree advanced main')
        self.git('branch', '-f', 'main', newer_main)
        request = self.review.request_merge(reviewed, '', '')
        self.assertNotEqual(self.review.revision, original)
        self.assertEqual(request['targetHead'], newer_main)
        self.review.refresh()
        duplicate = self.review.request_merge(reviewed, '', '')
        self.assertEqual(request['id'], duplicate['id'])
        self.notify.assert_called_once()
        self.assertIn('First fetch', request['prompt'])
        self.assertIn('configured upstream', request['prompt'])
        self.assertIn('then rebase', request['prompt'])
        with self.assertRaisesRegex(ValueError, 'Rebase onto the target'):
            self.review.start_merge(self.review.revision, 'fix(test): prepared', 'Validation still requires the latest target.')

    def test_approval_must_match_the_diff_and_can_be_withdrawn(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        self.write('Interactor.swift', 'changed after approval\n')
        with self.assertRaisesRegex(ValueError, 'Reviewed files changed'):
            self.review.request_merge(request['reviewedRevision'], '', '')
        self.review.refresh()
        with self.assertRaisesRegex(ValueError, 'Withdraw'):
            self.review.request_merge(self.review.approval_revision(), '', '')
        self.review.cancel_merge_request(request['id'])
        with self.assertRaisesRegex(ValueError, 'pending approval'):
            self.review.execute_merge_request(request['id'], 'fix(test): change', 'Description')
        self.assertEqual(self.review.merge_request()['status'], 'cancelled')
        updated = self.review.request_merge(self.review.approval_revision(), '', '')
        self.assertNotEqual(updated['id'], request['id'])

    def test_approval_cannot_follow_unreviewed_content_after_another_tab_refreshes(self):
        reviewed = self.review.state()['merge']['revision']
        self.write('Interactor.swift', 'unreviewed change\n')
        self.review.refresh()
        with self.assertRaisesRegex(ValueError, 'Reviewed files changed'):
            self.review.request_merge(reviewed, '', '')
        self.notify.assert_not_called()

    def test_approval_survives_committing_the_reviewed_content(self):
        reviewed = self.review.state()['merge']['revision']
        self.git('add', '.')
        self.git('commit', '-m', 'fix(test): record reviewed content')
        request = self.review.request_merge(reviewed, '', '')
        self.assertEqual(request['head'], self.git('rev-parse', 'HEAD'))
        self.assertEqual(request['reviewedRevision'], reviewed)

    def test_approval_does_not_follow_a_branch_switch_during_refresh(self):
        reviewed = self.review.approval_revision()
        refresh = self.review.refresh
        def switch_branch():
            self.git('checkout', '-b', 'other')
            refresh()
        with patch.object(self.review, 'refresh', side_effect=switch_branch):
            with self.assertRaisesRegex(ValueError, 'branch changed'):
                self.review.request_merge(reviewed, '', '')
        self.notify.assert_not_called()

    def test_only_an_agent_can_execute_a_matching_request_and_report_result(self):
        with self.assertRaisesRegex(ValueError, 'pending approval'):
            self.review.execute_merge_request('missing', 'fix(test): change', 'Description')
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        def agent_merge(revision, title, description):
            self.assertEqual(revision, request['revision'])
            self.review.job = {'status': 'merged', 'log': 'Validated and merged'}
        with patch.object(self.review, 'start_merge', side_effect=agent_merge) as merge:
            self.review.execute_merge_request(request['id'], 'fix(test): change', 'Description')
            merge.assert_called_once()
        self.assertEqual(self.review.merge_request()['status'], 'merged')
        with self.assertRaises(ValueError):
            self.review.execute_merge_request(request['id'], 'fix(test): change', 'Description')

    def test_launch_detaches_and_does_not_duplicate_a_running_execution(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        with patch.object(m.subprocess, 'Popen') as launch:
            launch.return_value.pid = os.getpid()
            result = self.review.launch_merge_request(request['id'], 'fix(test): detached', 'Validation survives its shell.')
            self.assertEqual(result['mergePid'], os.getpid())
            self.assertTrue(launch.call_args.kwargs['start_new_session'])
            self.assertEqual(launch.call_args.kwargs['stdin'], subprocess.DEVNULL)
            self.assertNotEqual(launch.call_args.kwargs['stdout'], subprocess.PIPE)
            self.assertIn('--merge-worker', launch.call_args.args[0])
            self.review.launch_merge_request(request['id'], 'fix(test): detached', 'Validation survives its shell.')
            launch.assert_called_once()
        self.review.cancel_merge_request(request['id'])
        with self.assertRaisesRegex(ValueError, 'pending approval'):
            self.review.launch_merge_request(request['id'], 'fix(test): detached', 'Withdrawn approval stays withdrawn.')

    def test_detached_execution_finishes_after_launching_process_exits(self):
        self.write('.config/local-review.toml', "[merge]\ncommand = ['git', 'status', '--short']\n"
                   "[[merge.prepare]]\ncommand = ['python3', '-c', 'from pathlib import Path; Path(\"Interactor.swift\").write_text(\"let value = 3\")']\n"
                   "[[merge.checks]]\ncommand = ['python3', '-c', 'from pathlib import Path; import time; assert Path(\"Interactor.swift\").read_text() == \"let value = 3\"; time.sleep(.4)']\n")
        self.review.refresh()
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        description = self.root / '.git/description.txt'
        description.write_text('Survive the short-lived launching shell.')
        with m.queue_slot(self.review.store, request['id'], conversation=request['agent']):
            result = subprocess.run([sys.executable, str(TOOL / 'server.py'), '--repo', str(self.root),
                '--execute-merge-request', request['id'], '--title', 'fix(test): durable',
                '--description-file', str(description)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            execution = json.loads(result.stdout)
            for _ in range(200):
                saved = self.review.merge_request()
                if saved['status'] == 'merged':
                    break
                time.sleep(.05)
        self.assertEqual(saved['status'], 'merged', Path(execution['executionLog']).read_text())
        self.assertEqual(self.git('log', '-1', '--format=%s'), 'fix(test): durable')

    def test_failed_attempt_can_be_withdrawn_before_retry(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        self.write('Modules/App.swift', 'agent correction\n')
        with patch.object(self.review, 'command', side_effect=ValueError('build failed')):
            with self.assertRaisesRegex(ValueError, 'retry the same request'):
                self.review.execute_merge_request(request['id'], 'fix(test): corrected', 'Final behavior and validation.')
        self.assertEqual(self.review.merge_request()['status'], 'pending')
        self.review.cancel_merge_request(request['id'])
        with patch.object(self.review, 'start_merge') as merge:
            with self.assertRaisesRegex(ValueError, 'pending approval'):
                self.review.execute_merge_request(request['id'], 'fix(test): corrected', 'Final behavior and validation.')
            merge.assert_not_called()

    def test_delegated_approval_never_follows_a_different_branch(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        self.git('checkout', '-b', 'other')
        with patch.object(self.review, 'start_merge') as merge:
            with self.assertRaisesRegex(ValueError, 'branch or target changed'):
                self.review.execute_merge_request(request['id'], 'fix(test): corrected', 'Final behavior and validation.')
            merge.assert_not_called()
        self.assertEqual(self.review.merge_request()['status'], 'pending')

    def test_interrupted_attempt_returns_to_pending_and_can_be_retried(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        exited = subprocess.Popen([sys.executable, '-c', 'pass'])
        exited.wait()
        m.write_json(Path(request['path']), {**request, 'status': 'working', 'mergePid': exited.pid})
        def agent_merge(revision, title, description):
            self.assertEqual(self.review.merge_request()['status'], 'pending')
            self.review.job = {'status': 'merged', 'log': 'Validated and merged'}
        with patch.object(self.review, 'start_merge', side_effect=agent_merge):
            self.review.execute_merge_request(request['id'], 'fix(test): change', 'Description')
        self.assertEqual(self.review.merge_request()['status'], 'merged')
        self.assertEqual(self.review.merge_request()['mergePid'], os.getpid())

    def test_running_attempt_is_not_recovered(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        m.write_json(Path(request['path']), {**request, 'status': 'working', 'mergePid': os.getpid()})
        with patch.object(self.review, 'start_merge') as merge:
            with self.assertRaisesRegex(ValueError, 'pending approval'):
                self.review.execute_merge_request(request['id'], 'fix(test): change', 'Description')
            merge.assert_not_called()
        self.assertEqual(self.review.merge_request()['status'], 'working')
        self.assertTrue(self.review.merge_progress(request['id'])['running'])

    def test_review_pages_are_never_opened_automatically(self):
        self.assertNotIn('webbrowser', vars(m))
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        self.assertIn('Do not open review or queue pages in any browser', request['prompt'])
        self.assertIn('the user opens them manually', request['prompt'])

    def test_worker_prompt_polls_the_detached_execution_without_duplicate_attempts(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        self.assertIn('survives shell time limits', request['prompt'])
        self.assertIn('Do not start another attempt while its mergePid is alive', request['prompt'])
        self.assertIn('--merge-request ' + request['id'] + ' until merged, or pending with no live mergePid', request['prompt'])
        self.assertIn('keep handling the request until it finishes', request['prompt'])

    def queued_pair(self):
        first = self.review.request_merge(self.review.approval_revision(), '', '')
        second = {**first, 'id': 'b' * 24, 'sessionId': 'other', 'requestedAt': '9999-01-01T00:00:00+00:00',
                  'path': str(self.review.store / 'other-merge-request.json')}
        m.write_json(Path(second['path']), second)
        return first, second

    def test_queue_snapshot_includes_committed_and_dirty_changes_without_staging(self):
        self.git('add', '.')
        self.git('commit', '-m', 'fix(test): committed change')
        self.write('Interactor.swift', 'let value = 3\n')
        self.write('new.txt', 'approved untracked file\n')
        before = self.git('rev-parse', 'HEAD'), self.git('diff', '--cached'), self.git('status', '--porcelain')
        self.review.refresh()
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        self.assertEqual(before, (self.git('rev-parse', 'HEAD'), self.git('diff', '--cached'), self.git('status', '--porcelain')))
        self.assertEqual(self.git('show', request['snapshotRef'] + ':Interactor.swift'), 'let value = 3')
        self.assertEqual(self.git('show', request['snapshotRef'] + ':new.txt'), 'approved untracked file')
        self.assertEqual(self.git('rev-parse', request['snapshotRef'] + '^'), request['snapshotBase'])
        self.assertEqual(request['changedPaths'], ['Interactor.swift', 'new.txt'])
        with tempfile.TemporaryDirectory() as directory:
            consumer = Path(directory) / 'consumer'
            self.git('worktree', 'add', '-b', 'consumer', str(consumer), 'main')
            self.git('-C', str(consumer), 'merge', '--no-edit', request['snapshotRef'])
            self.assertEqual((consumer / 'Interactor.swift').read_text(), 'let value = 3\n')

    def test_queue_snapshot_accepts_lfs_images_with_identical_reviewed_content(self):
        image = b'\x89PNG\r\n\x1a\nsnapshot image bytes\n'
        oid = m.digest(image)
        pointer = f'version https://git-lfs.github.com/spec/v1\noid sha256:{oid}\nsize {len(image)}\n'
        object_path = self.review.common / 'lfs/objects' / oid[:2] / oid[2:4] / oid
        object_path.parent.mkdir(parents=True)
        object_path.write_bytes(image)
        # Model Git LFS's clean filter without requiring git-lfs in the test environment.
        clean = shlex.join([sys.executable, '-c', 'import sys; sys.stdin.buffer.read(); sys.stdout.write(' + repr(pointer) + ')'])
        self.git('config', 'filter.test-lfs.clean', clean)
        self.write('.gitattributes', '*.png filter=test-lfs -text\n')
        (self.root / 'snapshot.png').write_bytes(image)
        self.review.refresh()
        reviewed = self.review.approval_revision()

        request = self.review.request_merge(reviewed, '', '')

        self.assertEqual(self.git('show', request['snapshotRef'] + ':snapshot.png'), pointer.strip())
        captured = self.review.capture(before=request['snapshotBase'], after=request['snapshotCommit'])
        snapshot_file = next(file for file in captured[3] if file['path'] == 'snapshot.png')
        live_file = next(file for file in self.review.files if file['path'] == 'snapshot.png')
        self.assertEqual(snapshot_file['fingerprint'], live_file['fingerprint'])
        self.assertEqual(captured[4][snapshot_file['id']]['new'], image)
        self.write('Interactor.swift', 'changed after approval\n')
        with self.assertRaisesRegex(ValueError, 'Reviewed files changed'):
            self.review.request_merge(reviewed, '', '')

    def test_later_execution_does_not_start_validation_and_history_survives_reapproval(self):
        first, second = self.queued_pair()
        self.review.session_id = 'other'
        with patch.object(self.review, 'start_merge') as merge:
            with self.assertRaisesRegex(ValueError, 'ahead of this request'):
                self.review.execute_merge_request(second['id'], 'fix(test): later', 'Do not validate before the first merge.')
            merge.assert_not_called()
        queue = self.review.merge_queue()
        self.assertEqual([r['id'] for r in queue['pending']], [first['id'], second['id']])
        self.assertEqual([r['position'] for r in queue['pending']], [1, 2])
        self.review.session_id = first['sessionId']
        m.write_json(Path(first['path']), {**first, 'status': 'merged', 'finishedAt': '2026-10-13T10:00:00+00:00'})
        self.review.request_merge(self.review.approval_revision(), '', '')
        self.assertEqual(self.review.merge_queue()['recent'][0]['id'], first['id'])
        self.assertEqual(self.review.merge_request(first['id'])['status'], 'merged')
        self.assertEqual(self.review.merge_progress(first['id'])['id'], first['id'])

    def test_dead_worker_does_not_block_queue_or_hide_a_live_execution(self):
        first, second = self.queued_pair()
        exited = subprocess.Popen([sys.executable, '-c', 'pass'])
        exited.wait()
        m.write_json(Path(first['path']), {**first, 'workerPid': exited.pid})
        queue = self.review.merge_queue()
        self.assertEqual(queue['next'], second['id'])
        self.assertEqual(queue['attention'][0]['id'], first['id'])
        m.write_json(Path(first['path']), {**first, 'status': 'working', 'workerPid': exited.pid, 'mergePid': os.getpid()})
        self.assertEqual(self.review.merge_queue()['current'], first['id'])

    def test_queue_worker_reservation_allows_only_its_execution_child(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        with m.queue_slot(self.review.store, request['id']):
            self.assertEqual(self.review.merge_queue()['current'], request['id'])
            with self.assertRaisesRegex(ValueError, 'ahead of this request'):
                with m.queue_slot(self.review.store, request['id']):
                    self.fail('A second process must not steal preparation')
            with patch.dict(os.environ, {'LOCAL_REVIEW_QUEUE_PID': str(os.getpid())}):
                with m.queue_slot(self.review.store, request['id']):
                    self.assertTrue((self.review.store / 'queue-owner.json').exists())
        self.assertFalse((self.review.store / 'queue-owner.json').exists())

    def test_snapshot_cannot_capture_files_changed_after_approval(self):
        snapshot = self.review.snapshot
        def changing_snapshot(name):
            self.write('Interactor.swift', 'let value = 99\n')
            return snapshot(name)
        with patch.object(self.review, 'snapshot', side_effect=changing_snapshot):
            with self.assertRaisesRegex(ValueError, 'Files changed while saving'):
                self.review.request_merge(self.review.approval_revision(), '', '')
        self.assertIsNone(self.review.merge_request())
        self.notify.assert_not_called()

    def test_resume_cli_reuses_stopped_approval_and_rejects_live_or_withdrawn_worker(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        m.write_json(Path(request['path']), {**request, 'status': 'blocked', 'workerPid': None})
        argv = ['server.py', '--repo', str(self.root), '--resume-merge-request', request['id']]
        with patch.object(sys, 'argv', argv), patch('sys.stdout', new=io.StringIO()):
            m.main()
        resumed = self.review.merge_request()
        self.assertEqual(resumed['status'], 'pending')
        for field in ('id', 'requestedAt', 'snapshotRef', 'snapshotCommit'):
            self.assertEqual(resumed[field], request[field])
        self.assertEqual(self.notify.call_count, 2)
        for fields in ({'workerPid': os.getpid()}, {'status': 'cancelled'}):
            m.write_json(Path(request['path']), {**resumed, **fields})
            with patch.object(sys, 'argv', argv), patch('sys.stderr', new=io.StringIO()):
                with self.assertRaises(SystemExit):
                    m.main()
        self.assertEqual(self.notify.call_count, 2)

    def test_real_delivery_waits_before_launch_and_skips_withdrawn_queue_item(self):
        self.check_delivery_queue(cancel_later=True)

    def test_real_delivery_launches_second_worker_only_after_first_finishes(self):
        self.check_delivery_queue(cancel_later=False)

    def check_delivery_queue(self, cancel_later):
        first, second = self.queued_pair()
        cli = self.review.store / 'fake-worker'
        cli.write_text('''#!/usr/bin/env python3
import fcntl, json, os, re, sys, time
from pathlib import Path
prompt = sys.argv[sys.argv.index("--message") + 1] if sys.argv[1] == "queue" else sys.stdin.read()
path = Path(re.search(r" at (.*?) and verify", prompt).group(1))
request = json.loads(path.read_text())
with (path.parent / 'queue.lock').open('a') as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        raise AssertionError('Agent started without a queue reservation')
(path.parent / (request['id'] + '-started')).touch()
deadline = time.monotonic() + 10
while not (path.parent / 'release').exists():
    if time.monotonic() > deadline:
        raise AssertionError('Timed out waiting for test release')
    time.sleep(.05)
request.update(status='merged', summary='Validated once after preparation')
temp = path.with_suffix('.tmp')
temp.write_text(json.dumps(request))
temp.replace(path)
if '--output-last-message' in sys.argv:
    Path(sys.argv[sys.argv.index('--output-last-message') + 1]).write_text('Merged')
''')
        cli.chmod(0o755)
        for request in (first, second):
            request['agent'] = {**request['agent'], 'cli': str(cli)}
            request['prompt'] = request['prompt'].replace(first['path'], request['path'])
            m.write_json(Path(request['path']), request)
        processes = []
        def launch(request):
            process = subprocess.Popen([sys.executable, str(m.ASSETS / 'agent.py'), request['path']],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(process)
            return process
        def cleanup():
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)
        self.addCleanup(cleanup)
        def until(predicate):
            deadline = time.monotonic() + 5
            while not predicate():
                if time.monotonic() > deadline:
                    self.fail('Queue state did not arrive')
                time.sleep(.05)
        # Launch later delivery first: arrival order, not process scheduling, wins.
        later = launch(second)
        until(lambda: m.read_json(Path(second['path']), {})['delivery'] == 'queued')
        earlier = launch(first)
        until(lambda: (self.review.store / (first['id'] + '-started')).exists())
        self.assertFalse((self.review.store / (second['id'] + '-started')).exists())
        self.assertEqual(self.review.merge_queue()['current'], first['id'])
        if cancel_later:
            m.write_json(Path(second['path']), {**m.read_json(Path(second['path']), {}), 'status': 'cancelled'})
            later.wait(timeout=5)
            self.assertFalse((self.review.store / (second['id'] + '-started')).exists())
        (self.review.store / 'release').touch()
        earlier.wait(timeout=5)
        later.wait(timeout=5)
        self.assertEqual(self.review.merge_request()['status'], 'merged')
        if not cancel_later:
            self.assertTrue((self.review.store / (second['id'] + '-started')).exists())
            self.assertEqual(m.read_json(Path(second['path']), {})['status'], 'merged')
        self.assertFalse((self.review.store / 'queue-owner.json').exists())

    def test_agent_delivery_uses_saved_context_and_preserves_result(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        request.pop('deliveryMode')
        m.write_json(Path(request['path']), request)
        def worker(command, **kwargs):
            self.assertIn('danger-full-access', command)
            self.assertIn('approval_policy="never"', command)
            self.assertIn(str(self.review.repo), command)
            self.assertEqual(kwargs['input'], request['prompt'])
            self.assertNotIn('CODEX_THREAD_ID', kwargs['env'])
            current = self.review.merge_request()
            self.assertEqual(current['delivery'], 'started')
            m.write_json(Path(request['path']), {**current, 'status': 'merged', 'summary': 'Done'})
            return subprocess.CompletedProcess(command, 0)
        with patch.dict(os.environ, {'CODEX_CLI_PATH': '/fake/codex', 'CODEX_THREAD_ID': 'original-chat'}), patch('agent.subprocess.run', side_effect=worker):
            deliver(request['path'])
        self.assertEqual(self.review.merge_request()['status'], 'merged')
        self.assertEqual(self.review.merge_request()['summary'], 'Done')

    def comment(self, text, resolved=False):
        file = self.review.files[0]
        comment = {'id': secrets.token_hex(8), 'file': file['id'], 'path': file['path'], 'side': 'new', 'line': 1, 'endLine': 1,
                   'text': text, 'resolved': resolved, 'fingerprint': file['fingerprint'], 'scope': 'full'}
        self.review.session['comments'].append(comment)
        self.review.save_session()
        return comment

    def send_review(self, note=''):
        with patch.object(m.Review, 'launch_review_worker', return_value=os.getpid()) as launch:
            handoff = self.review.send_review(note)
        launch.assert_called_once_with(Path(handoff['path']), handoff['id'])
        return handoff

    def test_send_review_hands_new_comments_to_the_originating_conversation(self):
        with self.assertRaisesRegex(ValueError, 'No new unresolved comments'):
            self.send_review()
        first = self.comment('Rename value to total.\nIt reads better.')
        self.comment('Already handled', resolved=True)
        self.assertEqual(self.review.state()['handoff']['unsent'], 1)
        handoff = self.send_review('Focus on naming.')
        self.assertEqual((handoff['status'], handoff['comments'], handoff['agent']['sessionId']), ('running', [first['id']], 'original-codex-chat'))
        self.assertIn(f"- [{first['id']}] Interactor.swift (new side, line 1)\n  Rename value to total.\n  It reads better.", handoff['prompt'])
        self.assertIn('Reviewer note:\nFocus on naming.', handoff['prompt'])
        self.assertIn(' --base main --begin-iteration', handoff['prompt'], 'The agent records into this review, whatever its target')
        self.assertNotIn('Already handled', handoff['prompt'])
        state = self.review.state()['handoff']
        self.assertEqual((state['unsent'], state['last']['id']), (0, handoff['id']))
        self.assertNotIn('prompt', state['last'])
        self.assertEqual(state['blocker'], 'The agent is still handling the previous review.')
        self.assertTrue(all(c.get('handoff') == handoff['id'] for c in m.read_json(self.review.store / f'{self.review.session_id}.json', {})['comments'] if not c['resolved']))
        with self.assertRaisesRegex(ValueError, 'still handling'):
            self.send_review('Again')
        m.write_json(Path(handoff['path']), {**handoff, 'workerPid': 2 ** 22 + 12345})
        self.assertEqual(self.review.review_handoff()['status'], 'failed', 'A dead worker cannot stay running')

    def test_send_review_waits_for_the_agent_turn_and_a_known_conversation(self):
        self.comment('Please add a test.')
        self.review.begin_iteration('turn-1', 'Change the value')
        with self.assertRaisesRegex(ValueError, 'still working on its current request'):
            self.send_review()
        self.review.finish_iteration('turn-1', 'Changed', 'feat(test): change value', 'Change the value.')
        self.review.session['agent'] = None
        self.review.session['threadId'] = None
        self.review.save_session('agent', 'threadId')
        with self.assertRaisesRegex(ValueError, 'No originating agent conversation'):
            self.send_review()

    def test_review_delivery_queues_into_codex_and_resumes_claude(self):
        self.comment('Rename value.')
        handoff = self.send_review()
        def codex(command, **kwargs):
            self.assertEqual(command, ['/fake/codex', 'queue', '--thread', 'original-codex-chat', '--message', handoff['prompt']])
            self.assertEqual((kwargs['cwd'], kwargs['input']), (str(self.review.repo), None))
            self.assertNotIn('CODEX_THREAD_ID', kwargs['env'])
            self.assertNotIn('LOCAL_REVIEW_HANDOFF', kwargs['env'], 'The original conversation keeps recording interactions')
            return subprocess.CompletedProcess(command, 0)
        with patch('agent.subprocess.run', side_effect=codex):
            deliver_review(handoff['path'])
        result = self.review.review_handoff()
        self.assertEqual(result['status'], 'delivered')
        self.assertIn('Review queued in the original Codex conversation', result['summary'])
        self.assertIsNone(self.review.handoff_blocker())
        self.comment('Another one.')
        self.review.session['agent'] = {'provider': 'claude', 'sessionId': 'claude-session-1', 'cli': '/fake/claude'}
        self.review.save_session('agent')
        handoff = self.send_review()
        def claude(command, **kwargs):
            self.assertEqual(command[:3], ['/fake/claude', '--resume', 'claude-session-1'])
            kwargs['stdout'].write(json.dumps({'type': 'result', 'result': 'Added it.'}) + '\n')
            return subprocess.CompletedProcess(command, 1)
        with patch('agent.subprocess.run', side_effect=claude):
            deliver_review(handoff['path'])
        self.assertEqual((self.review.review_handoff()['status'], self.review.review_handoff()['summary']), ('failed', 'Added it.'))

    def test_review_delivery_process_runs_the_agent_cli(self):
        self.comment('Rename value.')
        handoff = self.send_review()
        cli = self.root / '.git' / 'fake-codex'
        cli.write_text('#!/usr/bin/env python3\nimport sys\nassert sys.argv[1:4] == ["queue", "--thread", "original-codex-chat"]\n'
                       'assert sys.argv[4] == "--message"\nassert "Rename value." in sys.argv[5]\n')
        cli.chmod(0o755)
        m.write_json(Path(handoff['path']), {**handoff, 'agent': {**handoff['agent'], 'cli': str(cli)}})
        result = subprocess.run([m.sys.executable, str(m.ASSETS / 'agent.py'), '--review', handoff['path']],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.review.review_handoff()['status'], 'delivered')

    def test_failed_review_delivery_restores_comments_for_retry(self):
        comment = self.comment('Keep this feedback until Codex accepts it.')
        handoff = self.send_review()
        def failure(command, **kwargs):
            kwargs['stdout'].write('Could not queue the message.\n')
            return subprocess.CompletedProcess(command, 1)
        with patch('agent.subprocess.run', side_effect=failure):
            deliver_review(handoff['path'])
        state = self.review.handoff_state()
        self.assertEqual((state['last']['status'], state['unsent']), ('failed', 1))
        self.assertIn('Could not queue', state['last']['summary'])
        saved = m.read_json(self.review.store / f'{self.review.session_id}.json', {})['comments'][0]
        self.assertNotIn('sentAt', saved)
        retry = self.send_review()
        self.assertEqual(retry['comments'], [comment['id']])
        with patch('agent.subprocess.run', return_value=subprocess.CompletedProcess([], 0)):
            deliver_review(retry['path'])
        self.assertEqual((self.review.handoff_state()['last']['status'], self.review.handoff_state()['unsent']), ('delivered', 0))

    def test_merge_delivery_queues_original_codex_chat_and_holds_its_turn(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        self.assertEqual(request['deliveryMode'], 'conversation')
        observed = []
        def queued(command, **kwargs):
            self.assertEqual(command, ['/fake/codex', 'queue', '--thread', 'original-codex-chat', '--message', request['prompt']])
            self.assertIsNone(kwargs['input'])
            self.assertNotIn('CODEX_THREAD_ID', kwargs['env'])
            self.assertNotIn('LOCAL_REVIEW_HANDOFF', kwargs['env'])
            owner = m.read_json(self.review.store / 'queue-owner.json', {})
            self.assertEqual(owner['conversation']['sessionId'], 'original-codex-chat')
            return subprocess.CompletedProcess(command, 0)
        def finish(_):
            saved = self.review.merge_request()
            observed.append(saved['delivery'])
            self.assertEqual(saved['status'], 'pending', 'Successful queueing is not merge completion')
            self.assertTrue((self.review.store / 'queue-owner.json').exists())
            m.write_json(Path(request['path']), {**saved, 'status': 'merged'})
        with patch('agent.subprocess.run', side_effect=queued), patch('agent.time.sleep', side_effect=finish):
            deliver(request['path'])
        self.assertEqual(observed, ['delivered'])
        self.assertEqual(self.review.merge_request()['status'], 'merged')
        self.assertFalse((self.review.store / 'queue-owner.json').exists())

    def test_merge_delivery_resumes_original_claude_chat_and_releases_on_blocker(self):
        with patch.dict(os.environ, {'CLAUDECODE': '1', 'CLAUDE_CODE_SESSION_ID': 'claude-chat'}), patch.object(m.shutil, 'which', return_value='/fake/claude'):
            self.review.record_agent()
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        def resumed(command, **kwargs):
            self.assertEqual(command[:3], ['/fake/claude', '--resume', 'claude-chat'])
            self.assertNotIn('--session-id', command)
            self.assertNotIn('LOCAL_REVIEW_HANDOFF', kwargs['env'])
            self.assertEqual(kwargs['input'], request['prompt'])
            kwargs['stdout'].write(json.dumps({'type': 'result', 'result': 'A decision is required.'}) + '\n')
            return subprocess.CompletedProcess(command, 0)
        with patch('agent.subprocess.run', side_effect=resumed):
            deliver(request['path'])
        self.assertEqual(self.review.merge_request()['status'], 'blocked')
        self.assertEqual(self.review.merge_request()['summary'], 'A decision is required.')
        self.assertFalse((self.review.store / 'queue-owner.json').exists())

    def test_original_conversation_can_execute_only_its_reserved_request(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        conversation = request['agent']
        with m.queue_slot(self.review.store, request['id'], conversation=conversation):
            with m.queue_slot(self.review.store, request['id']):
                self.assertTrue((self.review.store / 'queue-owner.json').exists())
            with patch.dict(os.environ, {'CODEX_THREAD_ID': 'another-chat'}):
                with self.assertRaisesRegex(ValueError, 'ahead of this request'):
                    with m.queue_slot(self.review.store, request['id']):
                        self.fail('Another conversation must not inherit the reservation')
            self.review.cancel_merge_request(request['id'])
            with patch.object(self.review, 'start_merge') as merge:
                with self.assertRaisesRegex(ValueError, 'pending approval'):
                    self.review.execute_merge_request(request['id'], 'fix(test): change', 'Description')
                merge.assert_not_called()

    def test_merge_request_waits_for_current_interaction_and_review_handoff(self):
        self.review.begin_iteration('active', 'Still working')
        with self.assertRaisesRegex(ValueError, 'still working'):
            self.review.request_merge(self.review.approval_revision(), '', '')
        self.review.finish_iteration('active', 'Done', 'fix(test): finish work', 'Validation complete.')
        self.send_review('Please inspect this.')
        with self.assertRaisesRegex(ValueError, 'previous review'):
            self.review.request_merge(self.review.approval_revision(), '', '')
        self.assertIsNone(self.review.merge_request())
        self.notify.assert_not_called()

    def test_cancelled_approval_never_starts_worker_and_failure_is_visible(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        self.review.cancel_merge_request(request['id'])
        with patch('agent.subprocess.run') as worker:
            deliver(request['path'])
            worker.assert_not_called()
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        with patch.dict(os.environ, {'CODEX_CLI_PATH': '/missing/codex'}), patch('agent.subprocess.run', side_effect=FileNotFoundError('Missing CLI')):
            deliver(request['path'])
        self.assertEqual(self.review.merge_request()['status'], 'blocked')
        self.assertIn('Missing CLI', self.review.merge_request()['summary'])

    def test_detached_delivery_process_reports_worker_attention(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        request.pop('deliveryMode')
        m.write_json(Path(request['path']), request)
        cli = self.root / '.git' / 'fake-codex'
        cli.write_text('#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\nassert sys.argv[1] == "exec"\nassert "Handle release readiness" in sys.stdin.read()\nPath(sys.argv[sys.argv.index("--output-last-message") + 1]).write_text("A review comment needs your answer.")\n')
        cli.chmod(0o755)
        request['agent']['cli'] = str(cli)
        m.write_json(Path(request['path']), request)
        result = subprocess.run([m.sys.executable, str(m.ASSETS / 'agent.py'), request['path']],
            env={**os.environ, 'CODEX_CLI_PATH': str(cli)}, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.review.merge_request()['status'], 'blocked')
        self.assertEqual(self.review.merge_request()['summary'], 'A review comment needs your answer.')

    def test_merge_progress_is_bounded_live_and_keeps_the_worker_conversation(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        self.assertEqual(self.review.merge_progress()['log'], '')
        worker_id = '01a12013-1f5c-7720-8eb1-d7ded740b39e'
        log = self.review.merge_log_path()
        log.write_text(f'session id: {worker_id}\n' + 'earlier output\n' * 8000 + '\x1b[32mBuild started\x1b[0m\n')
        progress = self.review.merge_progress()
        self.assertEqual(progress['workerThreadId'], worker_id)
        self.assertTrue(progress['truncated'])
        self.assertTrue(progress['running'])
        self.assertTrue(progress['log'].endswith('Build started\n'))
        self.assertLessEqual(len(progress['log'].encode()), 65536)
        with log.open('a') as output:
            output.write('Tests passed\n')
        self.assertTrue(self.review.merge_progress()['log'].endswith('Tests passed\n'))
        m.write_json(Path(request['path']), {**request, 'status': 'merged', 'delivery': 'started'})
        (self.review.store / (request['id'] + '-agent-response.txt')).write_text('Merged')
        self.assertFalse(self.review.merge_progress()['running'], 'Legacy merged workers must stop polling after their final response')
        self.assertIn('earlier output', log.read_text(), 'The complete log remains downloadable')
        other = m.Review(self.root, 'main', auto_rank=False)
        other.session_id = 'different-session'
        self.assertEqual(other.state(merge_id=request['id'])['mergeRequest']['status'], 'merged')
        self.assertFalse(other.state(merge_id=request['id'])['canMerge'])
        self.assertEqual(other.merge_progress(request['id'])['workerThreadId'], worker_id)
        for invalid in ('../../private', '0' * 24):
            with self.assertRaises(ValueError):
                other.merge_progress(invalid)
        log.unlink()
        log.symlink_to(self.root / 'Interactor.swift')
        with self.assertRaisesRegex(ValueError, 'Invalid merge log'):
            self.review.merge_progress()

    def test_claude_stream_progress_is_readable_before_worker_exit(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        request['agent']['provider'] = 'claude'
        m.write_json(Path(request['path']), request)
        log = self.review.merge_log_path()
        events = [
            {'type': 'system', 'subtype': 'init', 'session_id': '01a12013-1f5c-7720-8eb1-d7ded740b39e'},
            {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Checking validation'}, {'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'mise run review:test'}}]}},
            {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'content': 'Tests passed'}]}},
            {'type': 'result', 'result': 'Merged successfully'},
        ]
        log.write_text('Startup warning\n' + '\n'.join(json.dumps(event) for event in events))
        progress = self.review.merge_progress()
        for text in ('Startup warning', '01a12013-1f5c-7720-8eb1-d7ded740b39e', 'Checking validation', 'mise run review:test', 'Tests passed', 'Merged successfully'):
            self.assertIn(text, progress['log'])
        self.assertIsNone(progress['workerThreadId'], 'Claude workers must not get Codex links')
        self.assertEqual(progress['provider'], 'claude')
        self.assertEqual(progress['workerSessionId'], events[0]['session_id'])
        with log.open('a') as output:
            output.write('\n' + json.dumps(events[1]) + '\n' + 'Older output\n' * 8000)
        self.assertEqual(self.review.merge_progress()['workerSessionId'], events[0]['session_id'], 'Session identity survives rolling-tail truncation')
        with patch.object(m.subprocess, 'run') as launch:
            with self.assertRaisesRegex(ValueError, 'still running'):
                self.review.open_claude_conversation()
            launch.assert_not_called()

    def test_open_claude_conversation_uses_saved_identity_and_installed_capabilities(self):
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        cli = self.root / 'Claude CLI'
        cli.write_text('fake')
        request.update(status='merged', delivery='finished', agent={'provider': 'claude', 'cli': str(cli)})
        m.write_json(Path(request['path']), request)
        session_id = '01a12013-1f5c-7720-8eb1-d7ded740b39e'
        self.review.merge_log_path().write_text(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': session_id}))
        for help_text, expected in [('--resume [value]\n', 'Claude in Terminal'), ('  --desktop    Open in desktop\n', 'Claude Desktop')]:
            with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'run', side_effect=[
                    subprocess.CompletedProcess([], 0, help_text, ''), subprocess.CompletedProcess([], 0, '', '')]) as launch:
                self.assertEqual(self.review.open_claude_conversation(request['id'])['destination'], expected)
                if expected == 'Claude Desktop':
                    self.assertEqual(launch.call_args.args[0], [str(cli), '--desktop', '--resume', session_id])
                    self.assertEqual(launch.call_args.kwargs['cwd'], self.root.resolve())
                    self.assertNotIn('CODEX_THREAD_ID', launch.call_args.kwargs['env'])
                else:
                    command = self.review.store / (request['id'] + '-resume-claude.command')
                    self.assertEqual(launch.call_args.args[0], ['/usr/bin/open', '-a', 'Terminal', str(command)])
                    script = command.read_text()
                    self.assertIn('--resume ' + session_id, script)
                    self.assertIn("'" + str(cli.resolve()) + "'", script)
                    self.assertIn('unset CLAUDECODE', script)
                    self.assertEqual(command.stat().st_mode & 0o777, 0o700)
        with patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'run', side_effect=[
                subprocess.CompletedProcess([], 0, '  --desktop\n', ''), subprocess.CompletedProcess([], 1, '', 'Desktop unavailable')]):
            with self.assertRaisesRegex(ValueError, 'Desktop unavailable'):
                self.review.open_claude_conversation()
        # A removed worktree must resume its real transcript from the surviving checkout.
        history = self.root / 'claude-config/projects/old-worktree'
        history.mkdir(parents=True)
        transcript = history / (session_id + '.jsonl')
        transcript.write_text('saved conversation')
        m.write_json(Path(request['path']), {**request, 'repo': str(self.root / 'removed-worktree')})
        with patch.dict(os.environ, {'CLAUDE_CONFIG_DIR': str(history.parent.parent)}), patch.object(m.sys, 'platform', 'darwin'), patch.object(m.subprocess, 'run', side_effect=[
                subprocess.CompletedProcess([], 0, '  --desktop\n', ''), subprocess.CompletedProcess([], 0, '', '')]):
            self.assertEqual(self.review.open_claude_conversation()['destination'], 'Claude in Terminal')
            command = self.review.store / (request['id'] + '-resume-claude.command')
            self.assertIn('--resume ' + str(transcript), command.read_text())
            self.assertEqual(self.review.merge_progress()['resumeCommand'], 'claude --resume ' + str(transcript))
        self.review.merge_log_path().write_text(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'bad; command'}))
        with patch.object(m.subprocess, 'run') as launch:
            with self.assertRaisesRegex(ValueError, 'No Claude worker'):
                self.review.open_claude_conversation()
            launch.assert_not_called()


    def test_origin_detection_and_switching_survive_server_environment(self):
        self.assertEqual(m.detect_agent()['provider'], 'codex')
        with patch.dict(os.environ, {'CLAUDECODE': '1', 'CLAUDE_CODE_SESSION_ID': 'claude-chat'}):
            self.assertEqual(m.detect_agent()['provider'], 'claude', 'Claude tool markers override inherited Codex markers')
            self.review.begin_iteration('claude-turn', 'Claude changes')
        self.assertEqual(self.review.origin_agent()['provider'], 'claude')
        self.assertEqual(self.review.session['pendingIteration']['agent']['sessionId'], 'claude-chat')
        stale_server = m.Review(self.root, 'main', auto_rank=False)
        self.review.record_agent()
        self.assertEqual(stale_server.state()['agent']['provider'], 'codex')
        with patch.dict(os.environ, {'CLAUDECODE': '1', 'LOCAL_REVIEW_HANDOFF': '1'}):
            self.assertIsNone(m.detect_agent())
            stale_server.record_agent()
        self.assertEqual(self.review.origin_agent()['sessionId'], 'original-codex-chat')
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(m.detect_agent())
            stale_server.record_agent()
        self.assertEqual(stale_server.origin_agent()['provider'], 'codex', 'A normal terminal does not replace a saved origin')

    def test_nested_sessions_use_the_nearest_agent_process(self):
        with patch.dict(os.environ, {'CLAUDECODE': '1', 'CLAUDE_CODE_SESSION_ID': 'parent-claude'}):
            for provider in ('codex', 'claude'):
                with patch.object(m, 'parent_agent', return_value=provider):
                    self.assertEqual(m.detect_agent()['provider'], provider)
        # Exercise the actual walk through shell and mise wrappers without launching agents.
        with patch.object(m, 'parent_agent', new=parent_agent_impl):
            for provider in ('codex', 'claude'):
                responses = [subprocess.CompletedProcess([], 0, '15 /bin/zsh\n'),
                             subprocess.CompletedProcess([], 0, f'10 /opt/bin/{provider}\n')]
                with patch.object(m.subprocess, 'run', side_effect=responses):
                    self.assertEqual(m.parent_agent(), provider)
            with patch.object(m.subprocess, 'run', side_effect=FileNotFoundError('ps unavailable')):
                self.assertIsNone(m.parent_agent())
            with patch.object(m.shutil, 'which', return_value='/fake/versions/2.1.169'), patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '10 /fake/versions/2.1.169\n')):
                self.assertEqual(m.parent_agent(), 'claude', 'Native Claude binaries use version filenames')

    def test_claude_delivery_uses_saved_origin_and_cleans_nested_markers(self):
        with patch.dict(os.environ, {'CLAUDECODE': '1', 'CLAUDE_CODE_SESSION_ID': 'claude-chat'}), patch.object(m.shutil, 'which', return_value='/fake/claude'):
            self.review.record_agent()
        request = self.review.request_merge(self.review.approval_revision(), '', '')
        request.pop('deliveryMode')
        m.write_json(Path(request['path']), request)
        self.assertIsNone(request['threadId'], 'Claude sessions must never create a Codex chat link')
        self.review.record_agent()
        self.assertEqual(self.review.origin_agent()['provider'], 'codex')
        def worker(command, **kwargs):
            self.assertEqual(command[0], '/fake/claude')
            self.assertIn('--print', command)
            self.assertEqual(command[command.index('--session-id') + 1], self.review.merge_request()['workerSessionId'])
            self.assertIn('dontAsk', command)
            self.assertIn('Bash', command)
            self.assertNotIn('--dangerously-skip-permissions', command)
            self.assertEqual(kwargs['cwd'], str(self.review.repo))
            self.assertEqual(kwargs['input'], request['prompt'])
            self.assertNotIn('CLAUDECODE', kwargs['env'])
            self.assertNotIn('CODEX_THREAD_ID', kwargs['env'])
            self.assertEqual(kwargs['env']['LOCAL_REVIEW_HANDOFF'], '1')
            self.assertIn('stream-json', command)
            self.assertIn('--verbose', command)
            kwargs['stdout'].write('A harmless startup warning\n')
            kwargs['stdout'].write(json.dumps({'type': 'result', 'result': 'Claude needs an answer to a comment.'}) + '\n')
            return subprocess.CompletedProcess(command, 0)
        with patch.dict(os.environ, {'CLAUDECODE': '1'}), patch('agent.subprocess.run', side_effect=worker):
            deliver(request['path'])
        saved = self.review.merge_request()
        self.assertEqual(saved['status'], 'blocked')
        self.assertEqual(saved['summary'], 'Claude needs an answer to a comment.')
        self.assertEqual((Path(saved['path']).parent / (saved['id'] + '-agent-response.txt')).read_text(), saved['summary'])

    def test_unknown_origin_never_guesses_a_runner_and_legacy_codex_survives(self):
        self.review.session.pop('agent')
        self.review.session['threadId'] = None
        self.review.save_session('agent', 'threadId')
        with self.assertRaisesRegex(ValueError, 'No originating agent'):
            self.review.request_merge(self.review.approval_revision(), '', '')
        self.review.session['threadId'] = 'legacy-codex-chat'
        self.review.save_session('threadId')
        self.assertEqual(self.review.origin_agent()['provider'], 'codex')

    def test_merge_message_requires_title_and_final_description(self):
        with self.assertRaisesRegex(ValueError, 'description'):
            self.review.start_merge(self.review.revision, 'feat(test): behavior', '')
        for title in ['missing scope', 'fix(test): bad\ninjection', 'fix(test): bad\rinjection']:
            with self.assertRaisesRegex(ValueError, 'Conventional'):
                self.review.validate_message(title, 'Final behavior and tests.')

    def test_merge_refuses_stale_attempts_but_comment_flags_do_not_block(self):
        revision = self.review.revision
        self.write('Interactor.swift', 'stale\n')
        with self.assertRaisesRegex(ValueError, 'moved'):
            self.review.start_merge(revision, 'fix(test): stale', 'Final change and validation.')
        self.review.refresh()
        self.review.session['comments'].append({'resolved': False})
        with patch.object(m.threading, 'Thread') as worker:
            self.review.start_merge(self.review.revision, 'fix(test): unresolved', 'Final change and validation.')
            worker.return_value.start.assert_called_once()
        self.review.job = {'status': 'idle', 'log': ''}
        self.review.session['comments'].clear()
        with self.assertRaisesRegex(ValueError, 'Conventional'):
            self.review.start_merge(self.review.revision, 'bad title', 'Final change and validation.')
        self.git('branch', '-f', 'main', self.git('commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-m', 'new target'))
        with self.assertRaisesRegex(ValueError, 'moved'):
            self.review.start_merge(self.review.revision, 'fix(test): target', 'Final change and validation.')

    def test_merge_refuses_branch_switch(self):
        self.git('checkout', '-b', 'other')
        with self.assertRaisesRegex(ValueError, 'branch changed'):
            self.review.start_merge(self.review.revision, 'fix(test): wrong branch', 'Final change and validation.')

    def test_merge_commit_and_worktrunk_command_keep_hooks(self):
        calls = []
        def command(args):
            calls.append(args)
            if args[0] == 'git':
                self.git(*args[1:])
        with patch.object(self.review, 'command', side_effect=command):
            self.review.merge(self.review.revision, 'feat(review): reviewed', 'Reviewed change with tests.')
        self.assertEqual(self.review.job['status'], 'merged', self.review.job)
        self.assertEqual(calls[-1], ['wt', 'merge', 'main', '--no-commit', '--no-rebase'])
        self.assertNotIn('--yes', calls[-1])
        self.assertEqual(self.git('log', '-1', '--format=%s'), 'feat(review): reviewed')

    @unittest.skipUnless(shutil.which('wt'), 'Worktrunk not installed')
    def test_real_worktrunk_merge_in_disposable_worktree(self):
        self.git('restore', '.')
        self.git('checkout', 'main')
        # TOML quoting is kept simple for the disposable hook.
        self.write('.config/wt.toml', "pre-merge = '''test \"$(cat Interactor.swift)\" = \"let value = 43\" && echo review-hook-ok'''\n")
        self.git('add', '.')
        self.git('commit', '-m', 'chore(test): hook')
        self.git('branch', '-f', 'feature', 'main')
        worktree = self.root / 'feature-worktree'
        self.git('worktree', 'add', str(worktree), 'feature')
        original_target = self.git('rev-parse', 'main')
        for value in (2, 3):
            (worktree / 'Interactor.swift').write_text(f'let value = {value}\n')
            subprocess.run(['git', 'add', '.'], cwd=worktree, check=True, capture_output=True)
            subprocess.run(['git', 'commit', '-m', f'fix(test): intermediate {value}'], cwd=worktree, check=True, capture_output=True)
        previous_tip = self.git('rev-parse', 'feature')
        (worktree / 'Interactor.swift').write_text('let value = 42\n')
        config = self.root / 'test-wt.toml'
        config.write_text('')
        review = m.Review(worktree, 'main')
        review.record_agent()
        review.session['comments'].append({'id': 'comment', 'text': 'Check the interactor', 'resolved': False})
        review.save_session()
        request = review.request_merge(review.approval_revision(), '', '')
        review.begin_iteration('turn', 'Approve and finish merging')
        # Target moves after approval; the agent commits its working changes and rebases.
        self.write('target.txt', 'new target content\n')
        self.git('add', 'target.txt')
        self.git('commit', '-m', 'fix(test): advance target')
        original_target = self.git('rev-parse', 'main')
        for args in (['add', '.'], ['commit', '-m', 'fix(test): prepare rebase'], ['rebase', 'main']):
            subprocess.run(['git', *args], cwd=worktree, check=True, capture_output=True)
        review.finish_iteration('turn', 'Prepared merge', 'fix(test): reviewed content', 'Final behavior and tests.')
        real_command = review.command
        def command(args):
            if args[0] == 'wt':
                args = ['wt', '--config', str(config), *args[1:], '--yes']
            real_command(args)
        # Approval applies only to the throwaway test hook, never the real repo.
        with patch.object(review, 'command', side_effect=command):
            with self.assertRaisesRegex(ValueError, 'retry the same request'):
                review.execute_merge_request(request['id'], 'fix(test): reviewed content', 'Final behavior and tests.')
            self.assertEqual(review.merge_request()['status'], 'pending')
            self.assertEqual(review.merge_request()['id'], request['id'])
            self.assertEqual(self.git('rev-parse', 'main'), original_target)
            self.assertEqual(self.git('rev-parse', 'refs/wt-backup/feature'), previous_tip)
            # Agent corrects the failing check without requiring resolved comments or fresh approval.
            (worktree / 'Interactor.swift').write_text('let value = 43\n')
            review.finish_iteration('turn', 'Corrected failed validation', 'fix(test): reviewed content', 'Final behavior and tests.')
            review.execute_merge_request(request['id'], 'fix(test): reviewed content', 'Update the interactor after local review.\n\nValidation: disposable Worktrunk hook.')
        self.assertEqual(review.merge_request()['status'], 'merged')
        self.assertFalse(review.session['comments'][0]['resolved'])
        self.assertEqual(len(review.session['iterations']), 1)
        self.assertEqual(review.job['status'], 'merged', review.job['log'])
        self.assertIn('review-hook-ok', review.job['log'])
        self.assertEqual((self.root / 'Interactor.swift').read_text(), 'let value = 43\n')
        self.assertEqual(self.git('rev-list', '--count', original_target + '..main'), '1')
        self.assertIn('Validation: disposable Worktrunk hook.', self.git('log', '-1', '--format=%B'))
        self.assertEqual(self.git('rev-parse', 'refs/wt-backup/feature'), previous_tip)
        for _ in range(100):
            if not worktree.exists():
                break
            time.sleep(.05)
        self.assertFalse(worktree.exists(), review.job['log'])
        historical = review.view('turn')
        self.assertEqual(historical[1][historical[0][0]['id']]['new'], b'let value = 43\n')

    def test_merge_checks_run_only_for_matching_paths(self):
        self.write('.config/local-review.toml', "[[merge.checks]]\npaths = ['^App/']\ncommand = ['make', 'run-app']\n")
        self.review.refresh()
        calls = []
        with patch.object(self.review, 'command', side_effect=lambda args: calls.append(args) or (args[0] == 'git' and self.git(*args[1:]))):
            self.review.merge(self.review.revision, 'feat(review): reviewed', 'Reviewed change with tests.')
        self.assertEqual(self.review.job['status'], 'merged', self.review.job)
        self.assertNotIn(['make', 'run-app'], calls)

    def test_preparation_formats_before_checks_and_freezes_the_result(self):
        self.write('.config/local-review.toml', "[[merge.prepare]]\npaths = ['\\.swift$']\ncommand = ['format', '{target}']\n"
                   "[[merge.checks]]\ncommand = ['build-app']\n")
        self.review.refresh()
        calls = []
        def command(args):
            calls.append(args)
            if args[0] == 'format':
                self.assertEqual(self.review.job['status'], 'running')
                with self.assertRaisesRegex(ValueError, 'Wait for the merge'):
                    self.review.refresh()
                self.write('Interactor.swift', 'let value = 3\n')
            elif args[0] == 'build-app':
                self.assertEqual((self.root / 'Interactor.swift').read_text(), 'let value = 3\n')
            elif args[0] == 'git':
                self.git(*args[1:])
        with patch.object(self.review, 'command', side_effect=command):
            self.review.start_merge(self.review.revision, 'fix(test): formatted', 'Format before expensive validation.')
            for _ in range(200):
                if self.review.job['status'] != 'running':
                    break
                time.sleep(.05)
        self.assertEqual(self.review.job['status'], 'merged', self.review.job)
        self.assertEqual(calls[:2], [['format', 'main'], ['build-app']])
        self.assertEqual(self.git('show', 'HEAD:Interactor.swift'), 'let value = 3')

    def test_drift_during_checks_still_fails_after_preparation(self):
        self.write('.config/local-review.toml', "[[merge.prepare]]\ncommand = ['format']\n"
                   "[[merge.checks]]\ncommand = ['build-app']\n")
        self.review.refresh()
        head = self.git('rev-parse', 'HEAD')
        def command(args):
            self.write('Interactor.swift', 'formatted\n' if args[0] == 'format' else 'changed during build\n')
        with patch.object(self.review, 'command', side_effect=command):
            self.review.merge(self.review.revision, 'fix(test): drift', 'Keep content drift checks.')
        self.assertEqual(self.review.job['status'], 'failed')
        self.assertIn('Files changed during validation', self.review.job['log'])
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)

    def test_failed_validation_does_not_stage_or_commit(self):
        self.write('.config/local-review.toml', "[[merge.checks]]\npaths = ['^App/']\ncommand = ['make', 'run-app']\n")
        self.write('App/App.swift', 'app code\n')
        self.review.refresh()
        head = self.git('rev-parse', 'HEAD')
        with patch.object(self.review, 'command', side_effect=ValueError('build failed')) as command:
            self.review.merge(self.review.revision, 'fix(test): app', 'App change after validation.')
        self.assertEqual(command.call_args.args[0], ['make', 'run-app'])
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual(self.review.job['status'], 'failed')

    def test_jev_combines_three_evaluators_and_caches(self):
        os.environ['JEV_API_KEY'] = 'test-key'
        result = {'answers': {name: {'noul': value} for name, value in [('business', .8), ('performance', .3), ('ui', .9)]}}
        with patch.object(m.urllib.request, 'urlopen', return_value=io.BytesIO(json.dumps(result).encode())) as request:
            self.review.rank()
            self.review.rank()
        self.assertEqual(request.call_count, 1)
        payload = json.loads(request.call_args.args[0].data)
        self.assertEqual(set(payload['questions']), {'business', 'performance', 'ui'})
        self.assertEqual(self.review.files[0]['score'], 90)
        self.assertEqual(self.review.files[0]['scorer'], 'Jev')

    def test_large_jev_diff_is_fully_evaluated_in_parts(self):
        os.environ['JEV_API_KEY'] = 'test-key'
        self.review.files[0]['patch'] = ('+change business logic\n' * 1500)
        requests = []
        def answer(request, timeout):
            requests.append(json.loads(request.data))
            return io.BytesIO(json.dumps({'answers': {name: {'noul': .7} for name in ('business', 'performance', 'ui')}}).encode())
        with patch.object(m.urllib.request, 'urlopen', side_effect=answer):
            self.review.rank()
        self.assertGreater(len(requests), 1)
        self.assertEqual(''.join(r['state']['diff'] for r in requests), self.review.files[0]['patch'])
        self.assertTrue(all(len(r['state']['diff'].encode()) <= 18000 for r in requests))
        self.assertEqual(self.review.files[0]['score'], 70)

    def test_jev_failure_and_sensitive_patch_keep_explicit_fallback(self):
        os.environ['JEV_API_KEY'] = 'test-key'
        with patch.object(m.urllib.request, 'urlopen', side_effect=OSError('offline')):
            self.review.rank()
        self.assertEqual(self.review.files[0]['scorer'], 'Fallback')
        self.assertEqual(self.review.ranking['fallbacks'], 1)
        self.review.files[0]['patch'] = '+let password = "private"'
        with patch.object(m.urllib.request, 'urlopen') as request:
            self.review.rank()
        request.assert_not_called()

    def test_dirty_submodule_cannot_be_approved_as_a_commit_pointer(self):
        sub = self.root / '.git' / 'submodule-fixture'
        sub.mkdir()
        def git_sub(*args):
            return subprocess.run(['git', *args], cwd=sub, check=True, capture_output=True)
        git_sub('init', '-b', 'main')
        git_sub('config', 'user.email', 'test@example.com')
        git_sub('config', 'user.name', 'Test')
        (sub / 'Model.swift').write_text('let model = 1\n')
        git_sub('add', '.')
        git_sub('commit', '-m', 'feat(test): model')
        self.git('-c', 'protocol.file.allow=always', 'submodule', 'add', str(sub), 'proto')
        self.git('add', '.')
        self.git('commit', '-m', 'feat(test): submodule')
        for path in ('Model.swift', 'untracked.swift'):
            with self.subTest(path=path):
                file = self.root / 'proto' / path
                file.write_text('let model = 2\n')
                self.review.refresh()
                self.assertTrue(next(f for f in self.review.files if f['path'] == 'proto')['submoduleDirty'])
                self.assertFalse(self.review.state()['canMerge'])
                with patch.object(self.review, 'snapshot') as snapshot:
                    with self.assertRaisesRegex(ValueError, 'uncommitted submodule'):
                        self.review.request_merge(self.review.approval_revision(), '', '')
                snapshot.assert_not_called()
                self.assertIsNone(self.review.merge_request())
                self.notify.assert_not_called()
                with self.assertRaisesRegex(ValueError, 'submodule'):
                    self.review.start_merge(self.review.revision, 'fix(test): dirty submodule', 'Final change and validation.')
                if path == 'Model.swift':
                    file.write_text('let model = 1\n')
                else:
                    file.unlink()

    def test_symlink_does_not_read_external_file(self):
        external = self.root.parent / ('review-secret-' + self.root.name)
        external.write_text('secret contents')
        self.addCleanup(external.unlink)
        (self.root / 'link').symlink_to(external)
        self.review.refresh()
        link = next(f for f in self.review.files if f['path'] == 'link')
        self.assertNotIn('secret contents', link['patch'])

    def test_review_time_is_cumulative_per_tab_scope_and_survives_restart(self):
        first = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        second = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        self.review.begin_iteration('timing-turn', 'Measure review')
        self.review.finish_iteration('timing-turn', 'Measured review', 'feat(test): timing', 'Measure focused review time. Validation: tests.')
        self.assertEqual(self.review.record_review_time(first, 'full', 1200)['totalMs'], 1200)
        self.review.record_review_time(first, 'full', 1200)
        self.review.record_review_time(first, 'full', 900)
        self.review.record_review_time(second, 'full', 500)
        self.review.record_review_time(first, 'timing-turn', 300)
        restarted = m.Review(self.root, 'main', auto_rank=False)
        self.assertEqual(restarted.state()['reviewTime'], {'totalMs': 2000, 'byScope': {'full': 1700, 'timing-turn': 300}})
        self.assertEqual(restarted.session['reviewTime']['full'][first], 1200)
        # CLI interaction updates and another server cannot overwrite these counters.
        restarted.begin_iteration('next-turn', 'Next review')
        self.review.record_review_time(first, 'full', 1500)
        saved = m.read_json(self.review.store / f'{self.review.session_id}.json', {})
        self.assertEqual(saved['pendingIteration']['id'], 'next-turn')
        self.assertEqual(saved['reviewTime']['full'][first], 1500)

    def test_review_time_keeps_the_newest_counted_intervals_per_visit(self):
        client = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        self.review.record_review_time(client, 'full', 1000, [[100, 1100]])
        self.review.record_review_time(client, 'full', 3000, [[100, 1100], [5000, 7000]])
        # A delayed older checkpoint cannot replace newer intervals.
        self.review.record_review_time(client, 'full', 1000, [[100, 1100]])
        self.review.record_review_time('b' * 36, 'full', 500)
        saved = m.read_json(self.review.store / f'{self.review.session_id}.json', {})
        self.assertEqual(saved['reviewTimeIntervals'], {'full': {client: [[100, 1100], [5000, 7000]]}})
        self.assertEqual(self.review.review_time()['totalMs'], 3500)
        for intervals in ['bad', [[2, 1]], [[1]], [[1, 2.5]], [[True, 2]], [[-1, 2]], [[1, 2]] * 501]:
            with self.subTest(intervals=intervals), self.assertRaises(ValueError):
                self.review.record_review_time(client, 'full', 9000, intervals)
        self.assertEqual(self.review.review_time()['totalMs'], 3500)

    def test_review_time_rejects_invalid_clients_scopes_and_durations(self):
        client = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        for bad_client, scope, duration in [('bad', 'full', 1), (client, 'missing', 1),
                                            (client, 'full', -1), (client, 'full', True),
                                            (client, 'full', 1.5), (client, 'full', float('nan')),
                                            (client, 'full', 2**53)]:
            with self.subTest(duration=duration, scope=scope), self.assertRaises(ValueError):
                self.review.record_review_time(bad_client, scope, duration)
        self.assertEqual(self.review.review_time()['totalMs'], 0)

    def test_http_auth_origin_comments_and_image_validation(self):
        server = m.ReviewServer(('127.0.0.1', 0), m.Handler)
        server.review, server.token, server.assets = self.review, 'test-token', {'index.html': b'hello'}
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f'http://127.0.0.1:{server.server_port}'
        def request(path, body=None, **headers):
            return urllib.request.urlopen(urllib.request.Request(url + path, data=None if body is None else json.dumps(body).encode(), headers={'X-Review-Token': 'test-token', 'Content-Type': 'application/json', **headers}))
        for headers in [{'X-Review-Token': 'bad'}, {'Origin': 'http://evil.example'}, {'Host': 'evil.example'}]:
            with self.assertRaises(urllib.error.HTTPError) as error:
                request('/api/simulator', {}, **headers)
            self.assertEqual(error.exception.code, 403)
            error.exception.close()
        for headers in [{'X-Review-Token': 'bad'}, {'Origin': 'http://evil.example'}]:
            with self.assertRaises(urllib.error.HTTPError) as error:
                request('/api/feedback', {'text': 'Rejected feedback'}, **headers)
            self.assertEqual(error.exception.code, 403)
            error.exception.close()
        with request('/api/feedback', {'text': '<script>literal feedback</script>'}) as response:
            inbox = json.load(response)
        self.assertEqual(inbox['entries'][0]['text'], '<script>literal feedback</script>')
        with request('/api/feedback') as response:
            self.assertEqual(len(json.load(response)['entries']), 1)
        with request('/api/queue') as response:
            self.assertEqual(json.load(response)['pending'], [])
        with self.assertRaises(urllib.error.HTTPError) as error:
            request('/api/queue', **{'X-Review-Token': 'bad'})
        self.assertEqual(error.exception.code, 403)
        error.exception.close()
        with self.assertRaises(urllib.error.HTTPError) as error:
            request('/api/feedback', {'text': '  '})
        self.assertEqual(error.exception.code, 400)
        error.exception.close()
        with patch.object(self.review, 'open_simulator', return_value={'id': 'assigned', 'name': 'Worktree'}) as launch:
            with request('/api/simulator', {'id': 'untrusted-client-id'}) as response:
                self.assertEqual(json.load(response)['simulator']['id'], 'assigned')
            launch.assert_called_once_with()
        with self.assertRaises(urllib.error.HTTPError) as error:
            request('/api/simulator')
        self.assertEqual(error.exception.code, 404, 'GET must not launch a native app')
        error.exception.close()
        client = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        for headers in [{'X-Review-Token': 'bad'}, {'Origin': 'http://evil.example'}]:
            with self.assertRaises(urllib.error.HTTPError) as error:
                request('/api/review-time', {'clientId': client, 'scope': 'full', 'elapsedMs': 400}, **headers)
            self.assertEqual(error.exception.code, 403)
            error.exception.close()
        with request('/api/review-time', {'clientId': client, 'scope': 'full', 'elapsedMs': 400}) as response:
            self.assertEqual(json.load(response)['totalMs'], 400)
        self.review.begin_iteration('http-turn', 'Adjust calculation')
        self.write('Interactor.swift', 'let value = 5\nlet next = 6\nlet last = 7\n')
        self.review.finish_iteration('http-turn', 'Adjusted calculation', 'fix(test): calculation', 'Adjust calculation. Validation: tests.')
        self.review.refresh()
        with request('/api/state?iteration=http-turn') as response:
            iteration_state = json.load(response)
        self.assertEqual(iteration_state['scope'], 'http-turn')
        self.assertEqual(iteration_state['merge']['revision'], self.review.approval_revision())
        historical_file = iteration_state['files'][0]
        with request('/api/comment?iteration=http-turn', {'file': historical_file['id'], 'fingerprint': historical_file['fingerprint'], 'side': 'new', 'line': 1, 'text': 'Iteration-only comment'}) as response:
            self.assertEqual(len(json.load(response)['session']['comments']), 1)
        self.assertEqual(len(self.review.state()['session']['comments']), 0)
        file = self.review.files[0]
        with request('/api/comment', {'file': file['id'], 'fingerprint': file['fingerprint'], 'side': 'new', 'line': 1, 'text': '<script>bad</script>'}) as response:
            data = json.load(response)
        self.assertEqual(data['session']['comments'][0]['text'], '<script>bad</script>')
        self.assertEqual(data['session']['comments'][0]['endLine'], 1, 'Legacy clients still create single-line comments')
        for suffix, target_file in [('', file), ('?iteration=http-turn', historical_file)]:
            comment = {'file': target_file['id'], 'fingerprint': target_file['fingerprint'], 'side': 'new', 'line': 1, 'endLine': 3, 'text': 'Review this whole block'}
            with request('/api/comment' + suffix, comment) as response:
                saved = json.load(response)['session']['comments'][-1]
            self.assertEqual((saved['line'], saved['endLine']), (1, 3))
            for invalid in [{'endLine': 0}, {'endLine': 999}, {'line': 0}, {'endLine': True}, {'side': 'old'}, {'side': 'file'}]:
                with self.assertRaises(urllib.error.HTTPError) as error:
                    request('/api/comment' + suffix, {**comment, **invalid})
                self.assertEqual(error.exception.code, 400)
                error.exception.close()
        reopened = m.Review(self.root, 'main', auto_rank=False)
        self.assertEqual(reopened.session['comments'][-1]['endLine'], 3)
        with request('/api/export') as response:
            self.assertEqual(json.load(response)['comments'][-1]['endLine'], 3)
        with self.assertRaises(urllib.error.HTTPError) as error:
            request('/api/comment', {'file': file['id'], 'fingerprint': file['fingerprint'], 'side': 'new', 'line': 999, 'text': 'invalid'})
        error.exception.close()
        with self.assertRaises(urllib.error.HTTPError) as error:
            request('/api/viewed', {'file': file['id'], 'fingerprint': 'stale', 'viewed': True})
        self.assertEqual(error.exception.code, 400)
        error.exception.close()
        with self.assertRaises(urllib.error.HTTPError) as error:
            request('/api/image?id=../../outside&side=new')
        error.exception.close()
        with patch.object(self.review, 'start_merge') as merge:
            with request('/api/merge', {'revision': self.review.approval_revision(), 'title': '', 'description': ''}) as response:
                approval = json.load(response)['mergeRequest']
            self.assertEqual(approval['status'], 'pending')
            merge.assert_not_called()
        self.review.merge_log_path().write_text('session id: 01a12013-1f5c-7720-8eb1-d7ded740b39e\n<script>literal log</script>\n')
        for headers in [{'X-Review-Token': 'bad'}, {'Origin': 'http://evil.example'}]:
            with self.assertRaises(urllib.error.HTTPError) as error:
                request('/api/merge-progress', **headers)
            self.assertEqual(error.exception.code, 403)
            error.exception.close()
        with patch.object(self.review, 'open_claude_conversation', return_value={'destination': 'Claude in Terminal'}) as launch:
            with request('/api/merge-conversation?merge=' + approval['id'], {'sessionId': 'untrusted', 'cli': '/bad'}) as response:
                self.assertEqual(json.load(response)['destination'], 'Claude in Terminal')
            launch.assert_called_once_with(approval['id'])
            for headers in [{'X-Review-Token': 'bad'}, {'Origin': 'http://evil.example'}]:
                with self.assertRaises(urllib.error.HTTPError) as error:
                    request('/api/merge-conversation', {}, **headers)
                self.assertEqual(error.exception.code, 403)
                error.exception.close()
            self.assertEqual(launch.call_count, 1)
        with request('/api/merge-progress') as response:
            self.assertIn('<script>literal log</script>', json.load(response)['log'])
        with request('/api/merge-log') as response:
            self.assertIn('text/plain', response.headers['Content-Type'])
            self.assertIn(b'<script>literal log</script>', response.read())
        with request('/api/state?merge=' + approval['id']) as response:
            self.assertFalse(json.load(response)['canMerge'])
        with request('/api/refresh?merge=' + approval['id'], {}) as response:
            self.assertEqual(json.load(response)['mergeRequest']['id'], approval['id'])
        with self.assertRaises(urllib.error.HTTPError) as error:
            request('/api/merge?merge=' + approval['id'], {'revision': self.review.revision})
        self.assertEqual(error.exception.code, 400)
        error.exception.close()
        with request('/api/merge/cancel', {'id': approval['id']}) as response:
            self.assertEqual(json.load(response)['mergeRequest']['status'], 'cancelled')
        with request('/api/shutdown', {}) as response:
            self.assertEqual(json.load(response)['status'], 'stopping')


if __name__ == '__main__':
    unittest.main()
