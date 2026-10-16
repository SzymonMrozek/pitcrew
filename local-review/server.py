#!/usr/bin/env python3
"""Local, persistent Git review. Python standard library only."""
import argparse
from contextlib import contextmanager
import difflib
from datetime import datetime, timezone
import fcntl
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
import mimetypes
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import socketserver
from urllib.parse import urlparse, parse_qs

ASSETS = Path(__file__).resolve().parent
AGENT_RUNTIME = ASSETS
WEB_ASSETS = ('index.html', 'app.mjs', 'context.mjs', 'definitions.mjs', 'diff.mjs', 'highlight.mjs', 'modules.mjs', 'review-time.mjs', 'stats.mjs', 'style.css', 'queue.html', 'queue.mjs', 'markdown.mjs', 'vendor/marked.mjs')
DEFAULTS = {
    "hideLocalization": True, "hideTests": True, "hideViews": False, "hideManifests": True, "hideGenerated": True,
    "exclude": [], "imageScale": 70, "diffMode": "split",
    "rubric": "Score review importance from 0 to 1. Prioritize changes affecting business logic, correctness, security, data integrity, concurrency, and application performance. Significant UI changes affecting interactions, accessibility, or user behavior need attention. Pure view styling and navigation changes usually have low importance because lint covers much of them. Do not penalize a performance or business-logic fix just because it is in a view. Localization and unit tests have low review importance. Snapshot changes deserve visual review. Evaluate the actual diff, not only the filename.",
}
MAX_TEXT = 2_000_000
MAX_SEARCH_RESULTS = 500
# Priority paths (for example module interfaces) sort near the top regardless of evaluation.
PRIORITY_SCORE = 95
# Data model types shape everything built on them, even when their diff looks like plain declarations.
MODEL_SCORE = 85
CONFIG_PATH = '.config/local-review.toml'
# Repository settings; .config/local-review.toml overrides any of them. Path patterns are Python
# regular expressions searched case-insensitively, except modules, which the browser evaluates.
CONFIG = {
    # Names the state directory in the Git common directory, the private ref namespace and the
    # <NAME>_HANDOFF / <NAME>_QUEUE_PID environment variables.
    'name': 'local-review',
    # Brand word shown before "review" in the page header and browser tab.
    'title': 'Local',
    # How people and agents invoke this CLI; merge agents receive commands built from it.
    'launcher': '',
    'files': {
        'snapshot': [r'/__snapshots__/', r'\.(png|jpe?g|webp)$'],
        'localization': [r'\.lproj/', r'\.(strings|stringsdict|xcstrings)$', r'/generated/strings', r'(^|/)l10n\.swift$'],
        # Protocol Buffers and gRPC output; review the .proto change instead.
        'generated': [r'\.(pb|grpc)\.swift$', r'\.pb(\.gw)?\.go$', r'_pb2(_grpc)?\.pyi?$', r'\.pb\.(h|cc)$',
                      r'\.pbobjc\.[hm]$', r'\.pb(json|enum|server)?\.dart$', r'_pb\.(js|d\.ts)$'],
        'manifest': [r'(^|/)Project\.swift$'],
        'test': [r'tests\.swift$', r'(^|/)tests/', r'\.test\.mjs$', r'(^|/)test[_-][^/]*$'],
        'view': [r'(^|/)(views|navigation)/', r'(view|coordinator|router)\.swift$'],
        # Code on these paths is a data model and never scores below MODEL_SCORE.
        'model': [r'(^|/)(models?|entities|dto)/', r'(model|content|state|entity|dto)\.(swift|kt|java|ts|py|go|rs)$'],
        # Fallback scores rank code paths matching this higher while no evaluator is available.
        'important': r'interactor|service|repository|resource|provider|stream|cache|auth',
    },
    # [{pattern, label}]: code changes on matching paths never score below PRIORITY_SCORE.
    'priority': [],
    # [{pattern}]: JavaScript regular expressions with named groups name, and optionally group and target.
    'modules': [],
    'simulator': {'metadata': '.worktree-simulator/simulator.env',
                  'udid-key': 'WORKTREE_SIMULATOR_UDID', 'name-key': 'WORKTREE_SIMULATOR_NAME'},
    'merge': {
        # {target} is replaced with the merge target branch.
        'command': ['wt', 'merge', '{target}', '--no-commit', '--no-rebase'],
        # [{paths, command}]: run before committing when any changed path matches.
        'checks': [],
        # Project rules appended to the merge agent's instructions.
        'instructions': '',
    },
}


def load_config(root):
    """Merge the repository configuration over the defaults; a removed worktree keeps the defaults."""
    config = json.loads(json.dumps(CONFIG))
    path = Path(os.environ.get('LOCAL_REVIEW_CONFIG') or Path(root) / CONFIG_PATH)
    try:
        with path.open('rb') as file:
            custom = tomllib.load(file)
    except FileNotFoundError:
        return config
    except tomllib.TOMLDecodeError as error:
        raise ValueError(f'Invalid {path}: {error}')
    for key, value in custom.items():
        if key not in config:
            raise ValueError(f'Unknown setting {key!r} in {path}')
        if isinstance(config[key], dict):
            if not isinstance(value, dict) or set(value) - set(config[key]):
                raise ValueError(f'Unknown setting in [{key}] of {path}')
            config[key].update(value)
        else:
            config[key] = value
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,40}', config['name']):
        raise ValueError(f'name in {path} must be lowercase letters, digits and dashes')
    for kind, patterns in config['files'].items():
        for pattern in [patterns] if isinstance(patterns, str) else patterns:
            re.compile(pattern)
    for item in config['priority']:
        re.compile(item['pattern'])
    for check in config['merge']['checks']:
        if not check.get('command') or not all(isinstance(arg, str) for arg in check['command']):
            raise ValueError(f'Each merge check in {path} needs a command list')
        for pattern in check.get('paths', []):
            re.compile(pattern)
    return config


def env_prefix(name):
    return re.sub(r'[^A-Z0-9]', '_', name.upper())


def launcher(config):
    return config['launcher'] or shlex.join([Path(sys.executable).name, str(ASSETS / 'server.py')])
# Type declarations that jump-to-definition can open; nested types are indexed by their own name.
SWIFT_DECLARATION = re.compile(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|package|final|indirect|nonisolated|static|(?:public|private|fileprivate|internal|package)\(set\))\s+)*(class|struct|enum|protocol|actor|typealias)\s+([A-Z]\w*)')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def process_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as file:
        file.write(json.dumps(value, indent=2) + '\n')
        temp = Path(file.name)
    try:
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def queue_requests(store):
    requests = []
    paths = list((store / 'queue-history').glob('*.json')) + list(store.glob('*-merge-request.json'))
    for path in paths:
        request = read_json(path, None)
        if not request:
            continue
        request = {**request, 'path': str(path)}
        if request['status'] in ('pending', 'working'):
            pids = [pid for pid in (request.get('workerPid'), request.get('mergePid')) if pid]
            if pids and not any(process_alive(pid) for pid in pids):
                request.update(status='blocked', summary='Merge worker stopped. Inspect and resume the same approval; no validation is running.')
        requests.append(request)
    return sorted({r['id']: r for r in requests}.values(), key=lambda r: (r['requestedAt'], r['id']))


@contextmanager
def queue_slot(store, request_id, wait=False):
    """Reserve preparation through cleanup, before launching any expensive work."""
    owner_path = store / 'queue-owner.json'
    owner = read_json(owner_path, {})
    # The execution CLI is a child of the worker already holding this reservation.
    if (owner.get('id') == request_id and owner.get('pid') == int(os.environ.get(env_prefix(store.name) + '_QUEUE_PID', '0'))
            and process_alive(owner.get('pid'))):
        yield
        return
    with (store / 'queue.lock').open('a') as lock:
        while True:
            requests = [r for r in queue_requests(store) if r['status'] in ('pending', 'working')]
            if not any(r['id'] == request_id for r in requests):
                raise ValueError('No matching active approval in the merge queue')
            acquired = False
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
            except BlockingIOError:
                pass
            if acquired:
                # Re-read after locking: an approval may have finished or been withdrawn.
                requests = [r for r in queue_requests(store) if r['status'] in ('pending', 'working')]
                if requests and requests[0]['id'] == request_id:
                    break
                fcntl.flock(lock, fcntl.LOCK_UN)
            if not wait:
                raise ValueError('Another merge is ahead of this request. Wait for its queue turn before rebasing or validating.')
            time.sleep(.5)
        write_json(owner_path, {'id': request_id, 'pid': os.getpid()})
        try:
            yield
        finally:
            owner_path.unlink(missing_ok=True)
            fcntl.flock(lock, fcntl.LOCK_UN)


def merge_queue(store):
    owner = read_json(store / 'queue-owner.json', {})
    entries = []
    for request in queue_requests(store):
        active = request['status'] in ('pending', 'working')
        phase = 'waiting' if active else request['status']
        if active and ((owner.get('id') == request['id'] and process_alive(owner.get('pid')))
                       or request['status'] == 'working' or (request.get('delivery') == 'started' and not request.get('workerPid'))):
            phase = 'merging' if request['status'] == 'working' else 'preparing'
        entries.append({key: request.get(key) for key in ('id', 'branch', 'target', 'repo', 'requestedAt', 'finishedAt',
                        'title', 'sessionId', 'snapshotRef', 'snapshotCommit', 'snapshotBase', 'changedPaths')} |
                       {'status': request['status'], 'phase': phase, 'provider': request.get('agent', {}).get('provider'),
                        'summary': request.get('summary', '')[-2000:] if request['status'] == 'blocked' else ''})
    pending = [r for r in entries if r['status'] in ('pending', 'working')]
    for position, request in enumerate(pending, 1):
        request['position'] = position
    return {'pending': pending, 'attention': [r for r in entries if r['status'] == 'blocked'],
            'recent': sorted([r for r in entries if r['status'] == 'merged'],
                             key=lambda r: r['finishedAt'] or r['requestedAt'], reverse=True)[:20],
            'current': next((r['id'] for r in pending if r['phase'] != 'waiting'), None),
            'next': pending[0]['id'] if pending else None}


def parent_agent():
    binaries = {str(Path(cli).resolve()): provider for provider, cli in (
        ('codex', os.environ.get('CODEX_CLI_PATH') or shutil.which('codex')), ('claude', shutil.which('claude'))
        ) if cli}
    pid = os.getppid()
    for _ in range(16):
        try:
            result = subprocess.run(['ps', '-ww', '-o', 'ppid=,comm=', '-p', str(pid)],
                                    capture_output=True, text=True, timeout=1)
            parent, command = result.stdout.strip().split(None, 1)
            name = Path(command).name.lower()
            if name in ('codex', 'claude'):
                return name
            if command in binaries:
                return binaries[command]
            pid = int(parent)
            if pid <= 1:
                break
        except (ValueError, OSError, subprocess.SubprocessError):
            break
    return None


def detect_agent(name=CONFIG['name']):
    if os.environ.get(env_prefix(name) + '_HANDOFF') == '1':
        return None  # A merge worker must not replace the originating conversation.
    claude_session = os.environ.get('CLAUDE_CODE_SESSION_ID')
    claude = bool(claude_session) or os.environ.get('CLAUDECODE', '').lower() in ('1', 'true', 'yes', 'on')
    codex_session = os.environ.get('CODEX_THREAD_ID') or os.environ.get('CODEX_SESSION_ID')
    # Both markers can be inherited when one agent launches the other.
    active_parent = parent_agent() if claude and codex_session else None
    if claude and active_parent != 'codex':
        return {'provider': 'claude', 'sessionId': claude_session, 'cli': shutil.which('claude')}
    if codex_session:
        return {'provider': 'codex', 'sessionId': codex_session,
                'cli': os.environ.get('CODEX_CLI_PATH') or shutil.which('codex')}
    return None


TITLE_SCANS = {}
TITLE_SCAN_LOCK = threading.Lock()


def last_jsonl_title(path, marker, field, entry_id=None):
    # Agents append title records to growing logs; read only what was added since the last poll.
    with TITLE_SCAN_LOCK:
        try:
            size = path.stat().st_size
        except OSError:
            return None
        key = (str(path), marker)
        offset, title = TITLE_SCANS.get(key, (0, None))
        if size < offset:
            offset, title = 0, None
        try:
            with path.open('rb') as file:
                file.seek(offset)
                remaining, pending = size - offset, b''
                while remaining > 0 and (chunk := file.read(min(4 << 20, remaining))):
                    remaining -= len(chunk)
                    lines = (pending + chunk).split(b'\n')
                    pending = lines.pop()
                    for line in lines:
                        if marker not in line:
                            continue
                        try:
                            entry = json.loads(line)
                        except ValueError:
                            continue
                        value = entry.get(field) if isinstance(entry, dict) and (entry_id is None or entry.get('id') == entry_id) else None
                        if isinstance(value, str) and value.strip():
                            title = value.strip()
                offset = size - remaining - len(pending)
        except OSError:
            return title
        TITLE_SCANS[key] = (offset, title)
        return title


def thread_title(agent):
    if not agent or not agent.get('sessionId'):
        return None
    session = agent['sessionId']
    if agent['provider'] == 'codex':
        index = Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex') / 'session_index.jsonl'
        return last_jsonl_title(index, session.encode(), 'thread_name', session)
    if not re.fullmatch(r'[A-Za-z0-9-]{1,80}', session):
        return None
    projects = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude') / 'projects'
    try:
        logs = sorted(projects.glob(f'*/{session}.jsonl'), key=lambda log: log.stat().st_mtime, reverse=True)
    except OSError:
        return None
    return last_jsonl_title(logs[0], b'"custom-title"', 'customTitle') if logs else None


def category(path, config=CONFIG):
    for kind in ('snapshot', 'localization', 'generated', 'manifest', 'test', 'view'):
        if any(re.search(pattern, path, re.I) for pattern in config['files'][kind]):
            return kind
    return 'code'


def priority(path, config=CONFIG):
    """Return the (label, minimum score) that keeps this path near the top, if any."""
    kind = category(path, config)
    if kind not in ('code', 'view'):
        return None
    label = next((item.get('label', 'Prioritized path') for item in config['priority'] if re.search(item['pattern'], path)), None)
    if label:
        return label, PRIORITY_SCORE
    if kind == 'code' and any(re.search(pattern, path, re.I) for pattern in config['files']['model']):
        return 'Data model', MODEL_SCORE
    return None


def fallback_score(path, config=CONFIG):
    kind = category(path, config)
    if kind in ('localization', 'generated', 'test', 'manifest'):
        return 10
    if floor := priority(path, config):
        return floor[1]
    if kind == 'view':
        return 25
    if kind == 'snapshot':
        return 40
    if config['files']['important'] and re.search(config['files']['important'], path, re.I):
        return 85
    return 60


def diff_rows(old, new):
    rows, old_line, new_line = [], 0, 0
    for line in difflib.unified_diff(old.splitlines(), new.splitlines(), n=4, lineterm=''):
        if line.startswith(('---', '+++')) and not rows:
            continue
        if line.startswith('@@'):
            match = re.match(r'@@ -(\d+)(?:,\d+)? \+(\d+)', line)
            old_line, new_line = map(int, match.groups())
            rows.append({'type': 'hunk', 'text': line, 'old': None, 'new': None})
            continue
        kind = {'+': 'add', '-': 'delete', ' ': 'context'}[line[0]]
        rows.append({'type': kind, 'text': line[1:], 'old': old_line if kind != 'add' else None, 'new': new_line if kind != 'delete' else None})
        old_line += kind != 'add'
        new_line += kind != 'delete'
    if not rows and old != new:
        rows.append({'type': 'hunk', 'text': 'End-of-file newline or line endings changed', 'old': None, 'new': None})
    return rows


class Review:
    def __init__(self, repo, target, state_dir=None, auto_rank=True, saved=None):
        self.repo = Path(repo).resolve()
        self.target = target
        self.auto_rank = auto_rank
        self.historical = {}
        common = Path(saved['common']) if saved else Path(self.git('rev-parse', '--path-format=absolute', '--git-common-dir').strip())
        self.common = common
        self.config = load_config(self.repo if self.repo.exists() else common.parent)
        self.store = state_dir or common / self.config['name']
        self.store.mkdir(parents=True, exist_ok=True)
        self.settings = {**DEFAULTS, **read_json(self.store / 'settings.json', {})}
        self.cache = read_json(self.store / 'scores.json', {})
        self.lock = threading.RLock()
        self.files = []
        self.blobs = {}
        self.job = {'status': 'idle', 'log': ''}
        self.ranking = {'status': 'idle', 'fallbacks': 0}
        self.rank_again = False
        self.definitions = None
        if saved:
            self.branch, self.session_id = saved['branch'], saved['sessionId']
            self.head, self.target_head = saved['head'], saved['targetHead']
            self.session = read_json(self.store / f'{self.session_id}.json', {'comments': [], 'viewed': {}, 'iterations': [], 'mergeDraft': {}})
            captured = self.capture(saved['base'], saved['tree'])
            self.base, self.files, self.blobs, self.revision = captured[2:]
            self.apply_scores()
        else:
            self.git('rev-parse', '--verify', target + '^{commit}')
            self.refresh()

    def git(self, *args, binary=False, check=True):
        result = subprocess.run(['git', *args] if self.repo.exists() else ['git', '--git-dir', str(self.common), *args], cwd=self.repo if self.repo.exists() else self.common, capture_output=True, timeout=30)
        if check and result.returncode:
            raise ValueError(result.stderr.decode(errors='replace').strip())
        return result.stdout if binary else result.stdout.decode(errors='replace')

    def work_blob(self, path):
        file = self.repo / path
        if file.is_symlink():
            return os.readlink(file).encode()
        if not file.resolve().is_relative_to(self.repo):
            raise ValueError('Path escapes the worktree')
        if file.is_dir():
            result = subprocess.run(['git', '-C', str(file), 'rev-parse', 'HEAD'], capture_output=True, timeout=10)
            return result.stdout
        return file.read_bytes() if file.is_file() else b''

    def lfs_blob(self, blob):
        if blob.startswith(b'version https://git-lfs.github.com/spec/v1\n'):
            match = re.search(rb'oid sha256:([a-f0-9]{64})\n', blob)
            if match:
                oid = match[1].decode()
                file = self.common / 'lfs/objects' / oid[:2] / oid[2:4] / oid
                if file.is_file():
                    return file.read_bytes()
        return blob

    def capture(self, before=None, after=None):
        head = after or self.git('rev-parse', 'HEAD').strip()
        target_head = before or self.git('rev-parse', self.target).strip()
        base = before or self.git('merge-base', self.target, 'HEAD').strip()
        names = self.git('diff', '--name-status', '--no-ext-diff', '--no-renames', '-z', base, *([after] if after else []), '--', binary=True).split(b'\0')
        changed = [(names[i].decode(), names[i + 1].decode('utf-8', 'surrogateescape')) for i in range(0, len(names) - 1, 2)]
        untracked = [] if after else self.git('ls-files', '--others', '--exclude-standard', '-z', binary=True).split(b'\0')
        changed += [('?', path.decode('utf-8', 'surrogateescape')) for path in untracked if path]
        files, blobs = [], {}
        for status, path in sorted(changed, key=lambda item: item[1]):
            old = self.git('show', f'{base}:{path}', binary=True, check=False) if status not in ('A', '?') else b''
            tree_entry = self.git('ls-tree', after, '--', path, binary=True) if after and status != 'D' else b''
            submodule = tree_entry.startswith(b'160000 ') if after else (self.repo / path).is_dir() and not (self.repo / path).is_symlink()
            # A saved tree's gitlink names a commit inside the submodule, which git show cannot read here.
            new = (self.git('show', f'{after}:{path}', binary=True) if after else self.work_blob(path)) if status != 'D' and not submodule else b''
            submodule_dirty = False
            if submodule:
                old = self.git('rev-parse', f'{base}:{path}', binary=True, check=False) if status not in ('A', '?') else b''
                if after:
                    new = self.git('rev-parse', f'{after}:{path}', binary=True)
                else:
                    new = self.work_blob(path)
                    result = subprocess.run(['git', '-C', str(self.repo / path), 'status', '--porcelain'], capture_output=True, timeout=30)
                    submodule_dirty = bool(result.returncode or result.stdout)
            # Executable-bit and symlink changes matter even with identical bytes.
            if after:
                mode = int(tree_entry.split(b' ', 1)[0], 8) if tree_entry else 0
            elif submodule:
                mode = 0o160000
            else:
                mode = (self.repo / path).lstat().st_mode if (self.repo / path).exists() or (self.repo / path).is_symlink() else 0
            # Git LFS stores pointers; compare the image bytes that the reviewer sees.
            old, new = self.lfs_blob(old), self.lfs_blob(new)
            file_id = digest(path.encode('utf-8', 'surrogateescape'))[:20]
            fingerprint = digest(old + b'\0' + new + b'\0' + str(mode).encode())
            kind = category(path, self.config)
            image = Path(path).suffix.lower() in ('.png', '.jpg', '.jpeg', '.webp')
            binary = image or b'\0' in old[:8192] + new[:8192]
            limited = not binary and max(len(old), len(new)) > MAX_TEXT
            rows = [] if binary or limited else diff_rows(old.decode(errors='replace'), new.decode(errors='replace'))
            patch = '\n'.join(('+' if row['type'] == 'add' else '-' if row['type'] == 'delete' else ' ') + row['text'] for row in rows)
            files.append({'id': file_id, 'path': path, 'status': status, 'kind': kind, 'image': image,
                          'binary': binary, 'limited': limited, 'submoduleDirty': submodule_dirty, 'fingerprint': fingerprint, 'patch': patch,
                          'rows': rows, 'added': sum(row['type'] == 'add' for row in rows),
                          'deleted': sum(row['type'] == 'delete' for row in rows), 'score': fallback_score(path, self.config), 'scorer': 'Fallback'})
            blobs[file_id] = {'old': old, 'new': new}
        revision = digest(json.dumps([head, target_head, [(f['path'], f['fingerprint']) for f in files]]).encode())
        return head, target_head, base, files, blobs, revision

    def score_key(self, file):
        return digest(('jev-review-v1' + file['path'] + file['fingerprint'] + self.settings['rubric']).encode())

    def refresh(self):
        with self.lock:
            if not self.repo.exists():
                return  # Removed worktrees retain their last saved diff and interaction trees.
            if self.job['status'] == 'running':
                raise ValueError('Wait for the merge to finish')
            self.config = load_config(self.repo)
            self.settings = {**DEFAULTS, **read_json(self.store / 'settings.json', {})}
            self.cache = read_json(self.store / 'scores.json', {})
            self.head, self.target_head, self.base, self.files, self.blobs, self.revision = self.capture()
            self.definitions = None
            self.historical.clear()
            if self.job['status'] == 'failed':
                self.job = {'status': 'idle', 'log': ''}
            branch = self.git('branch', '--show-current').strip()
            self.branch = branch
            self.session_id = self.review_identity(branch)
            self.session = read_json(self.store / f'{self.session_id}.json', {'comments': [], 'viewed': {}})
            self.session.setdefault('iterations', [])
            self.session.setdefault('mergeDraft', {'title': '', 'description': ''})
            self.apply_scores()
            self.start_ranking()

    def worktree_created(self):
        # Merging removes a Worktrunk worktree; recreating it reuses the path and branch name but not this file.
        marker = Path(self.git('rev-parse', '--path-format=absolute', '--git-dir').strip()) / 'commondir'
        try:
            return datetime.fromtimestamp(marker.stat().st_mtime, timezone.utc)
        except OSError:
            return None  # The main worktree has no per-worktree administrative directory.

    def review_identity(self, branch):
        legacy = digest((str(self.repo) + branch + self.target).encode())[:24]
        created = self.worktree_created()
        if created is None:
            return legacy
        current = digest((str(self.repo) + branch + self.target + '\0' + created.isoformat()).encode())[:24]
        if (self.store / f'{current}.json').exists():
            return current
        session = read_json(self.store / f'{legacy}.json', None)
        request = read_json(self.store / f'{legacy}-merge-request.json', None)
        if session is None and request is None and not (self.store / 'reviews' / f'{legacy}.json').exists():
            return current  # Never reviewed before, so no existing link or data needs the legacy identity.
        iterations = (session or {}).get('iterations', [])
        def earlier(stamp):
            try:
                return datetime.fromisoformat(stamp) < created
            except (TypeError, ValueError):
                return False
        if not earlier((request or {}).get('requestedAt')) and not any(earlier(item.get('finishedAt')) for item in iterations):
            return legacy  # Reviews started before identities included the worktree keep their links and data.
        # A previous worktree with this name owns the legacy review; carry over only this worktree's interactions.
        carried = [item for item in iterations if not earlier(item.get('finishedAt'))]
        pending = (session or {}).get('pendingIteration')
        if pending:
            # An interaction begins only after the previous one finished, so one recorded before startedAt existed follows the latest finished one.
            started = pending.get('startedAt') or max((item['finishedAt'] for item in iterations if item.get('finishedAt')), default=None)
            if started is None or earlier(started):
                pending = None  # Another agent's unfinished interaction in the previous worktree must not block this one.
        if carried or pending:
            fresh = {'comments': [], 'viewed': {}, 'iterations': [{**item, 'number': number} for number, item in enumerate(carried, 1)],
                     'mergeDraft': session['mergeDraft'] if carried else {'title': '', 'description': ''}}
            if pending:
                fresh['pendingIteration'] = pending
            for key in ('agent', 'threadId'):
                if key in session:
                    fresh[key] = session[key]
            write_json(self.store / f'{current}.json', fresh)
        return current

    def apply_scores(self, files=None):
        files = self.files if files is None else files
        for file in files:
            score = self.cache.get(self.score_key(file))
            if score is not None:
                file.update(**score, scorer='Jev')
            if floor := priority(file['path'], self.config):
                file.update(score=max(file['score'], floor[1]), priority=floor[0])
        files.sort(key=lambda file: (-file['score'], file['path']))

    def view(self, iteration=None):
        if not iteration:
            return self.files, self.blobs, self.revision, self.base
        if iteration == 'thread':
            return self.thread_view()
        item = next((i for i in self.session['iterations'] if i['id'] == iteration), None)
        if item is None:
            raise ValueError('Unknown interaction iteration')
        if iteration not in self.historical:
            captured = self.capture(item['before'], item['after'])
            self.historical[iteration] = captured
            if len(self.historical) > 3:
                self.historical.pop(next(iter(self.historical)))
            self.start_ranking()
        captured = self.historical[iteration]
        self.apply_scores(captured[3])
        return captured[3], captured[4], captured[5], captured[2]

    def thread_iterations(self):
        agent = self.origin_agent()
        items = [*self.session['iterations']]
        if pending := self.session.get('pendingIteration'):
            items.append(pending)
        return [item for item in items if agent and agent.get('sessionId') and (item.get('agent') or {}).get('provider') == agent['provider']
                and (item.get('agent') or {}).get('sessionId') == agent['sessionId']]

    def worktree_available(self):
        return self.repo.exists() and self.git('branch', '--show-current').strip() == self.branch

    def thread_view(self):
        items = self.thread_iterations()
        if not items:
            raise ValueError('This review has no recorded interaction baseline. Use Full diff.')
        if 'thread' not in self.historical:
            saved = read_json(self.store / 'reviews' / f'{self.session_id}.json', {})
            after = self.snapshot('thread-live') if self.worktree_available() else saved['tree']
            items = [{**item, 'after': item.get('after', after)} for item in items]
            # Undo only this chat's recorded edits in a private index. Dependencies imported
            # between interactions remain on both sides, including edits in the same file.
            with tempfile.TemporaryDirectory(dir=self.store) as directory:
                env = {**os.environ, 'GIT_INDEX_FILE': str(Path(directory) / 'index')}
                def git(*args, data=None):
                    result = subprocess.run(['git', '--git-dir', str(self.common), *args], env=env,
                                            input=data, capture_output=True, timeout=60)
                    if result.returncode:
                        raise ValueError('Cannot isolate recorded thread changes after overlapping updates. Use Full diff. ' + result.stderr.decode(errors='replace').strip())
                    return result.stdout
                git('read-tree', after)
                for item in reversed(items):
                    patch = self.git('diff', '--binary', '--full-index', '--unified=0', '--no-ext-diff', '--no-renames', item['before'], item['after'], binary=True)
                    if patch:
                        git('apply', '--cached', '--reverse', '--unidiff-zero', data=patch)
                before = git('write-tree').decode().strip()
            self.historical['thread'] = self.capture(before, after)
            self.start_ranking()
        captured = self.historical['thread']
        self.apply_scores(captured[3])
        return captured[3], captured[4], captured[5], captured[2]

    def approval_revision(self):
        # Approval follows reviewed file content; the target can advance before the worker rebases.
        return digest(json.dumps(sorted((file['path'], file['fingerprint']) for file in self.files)).encode())

    def state(self, iteration=None, merge_id=None):
        with self.lock:
            self.settings = {**DEFAULTS, **read_json(self.store / 'settings.json', {})}
            files, _, revision, base = self.view(iteration)
            scope = iteration or 'full'
            comments = [c for c in self.session['comments'] if c.get('scope', 'full') == scope]
            viewed = {k.split(':', 1)[-1]: v for k, v in self.session['viewed'].items() if k.startswith(scope + ':') or (scope == 'full' and ':' not in k)}
            live = self.worktree_available()
            clean = not self.git('status', '--porcelain', '--untracked-files=all').strip() if live else True
            agent = self.origin_agent()
            return {'repo': str(self.repo), 'branch': self.branch, 'target': self.target, 'head': self.head,
                    'base': base, 'revision': revision, 'scope': scope, 'files': [{k: v for k, v in f.items() if k not in ('patch', 'rows')} for f in files],
                    'reviewTime': self.review_time(),
                    'settings': self.settings, 'session': {'comments': comments, 'viewed': viewed}, 'job': self.job, 'ranking': self.ranking,
                    'iterations': self.session['iterations'], 'pendingIteration': self.session.get('pendingIteration'),
                    'threadScopeAvailable': bool(self.thread_iterations()),
                    'sessionId': self.session_id,
                    'threadId': self.session.get('threadId'),
                    'agent': agent,
                    'threadTitle': thread_title(agent) or self.session['mergeDraft'].get('title') or None,
                    'mergeRequest': self.merge_request(merge_id),
                    'handoff': None if merge_id else self.handoff_state(),
                    'merge': {'revision': self.approval_revision(), 'fileCount': len(self.files), 'unresolved': sum(not c['resolved'] for c in self.session['comments']), 'draft': self.session['mergeDraft']},
                    'dirty': not clean, 'jevAvailable': bool(os.environ.get('JEV_API_KEY')),
                    'tool': self.tool_info(),
                    'simulator': self.simulator() if live else None,
                    'canMerge': live and not merge_id and bool(self.files) and bool(self.branch) and self.branch != self.target
                                and not any(file['submoduleDirty'] for file in self.files)}

    def feedback(self):
        directory = self.store / 'feedback'
        return {'directory': str(directory), 'entries': [{'status': 'open', **read_json(path, {})} for path in sorted(directory.glob('*.json'), reverse=True)]}

    def set_feedback_status(self, entry_id, implemented):
        if not isinstance(entry_id, str) or not re.fullmatch(r'[0-9a-f]{32}', entry_id) or type(implemented) is not bool:
            raise ValueError('Unknown feedback')
        paths = list((self.store / 'feedback').glob(f'*-{entry_id}.json'))
        if len(paths) != 1:
            raise ValueError('Unknown feedback')
        entry = read_json(paths[0], {})
        for key in ('implementedAt', 'implementedBranch'):
            entry.pop(key, None)
        entry['status'] = 'implemented' if implemented else 'open'
        if implemented:
            entry.update(implementedAt=datetime.now(timezone.utc).isoformat(), implementedBranch=self.branch or None)
        write_json(paths[0], entry)
        return self.feedback()

    def save_feedback(self, text, file_id=None, iteration=None):
        if not isinstance(text, str) or not 1 <= len(text.strip()) <= 10000:
            raise ValueError('Feedback must contain 1–10000 characters')
        file = self.file(file_id, iteration) if file_id is not None else None
        if file_id is not None and file is None:
            if not isinstance(file_id, str) or not re.fullmatch(r'[0-9a-f]{20}', file_id):
                raise ValueError('Invalid feedback file')
            # Tool feedback is repository-wide; a stale optional file must not discard it.
            file = next((f for f in self.files if f['id'] == file_id), None)
        entry = {'id': secrets.token_hex(16), 'createdAt': datetime.now(timezone.utc).isoformat(),
                 'text': text.strip(), 'branch': self.branch, 'target': self.target,
                 'scope': iteration or 'full', 'revision': self.revision,
                 'repo': str(self.repo), 'sessionId': self.session_id, 'path': file['path'] if file else None}
        write_json(self.store / 'feedback' / (entry['createdAt'].replace(':', '-') + '-' + entry['id'] + '.json'), entry)
        return self.feedback()

    def simulator(self):
        if sys.platform != 'darwin':
            return None
        settings = self.config['simulator']
        metadata = self.repo / settings['metadata']
        if not metadata.is_file() or not metadata.resolve().is_relative_to(self.repo):
            return None
        try:
            values = dict(line.split('=', 1) for line in metadata.read_text().splitlines() if '=' in line)
            udid = shlex.split(values.get(settings['udid-key'], ''))
            if len(udid) != 1 or not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', udid[0]):
                return None
            name = ' '.join(shlex.split(values.get(settings['name-key'], 'Worktree simulator')))
            return {'id': udid[0], 'name': name, 'url': 'devices:///manage/select?id=' + udid[0]}
        except ValueError:
            return None

    def open_simulator(self):
        simulator = self.simulator()
        if not simulator:
            raise ValueError('This worktree has no assigned macOS simulator')

        def simctl(*args):
            result = subprocess.run(['xcrun', 'simctl', *args], cwd=self.repo, capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise ValueError('simctl failed: ' + (result.stderr.strip() or result.stdout.strip())[-2000:])
            return result.stdout

        try:
            groups = json.loads(simctl('list', 'devices', '--json'))['devices'].values()
        except (ValueError, KeyError, AttributeError):
            raise ValueError('simctl returned an unreadable device list')
        device = next((d for devices in groups for d in devices
                       if d.get('udid', '').lower() == simulator['id'].lower() and d.get('isAvailable', True)), None)
        if device is None:
            raise ValueError('The assigned simulator is unavailable or was removed. Recreate it with the worktree.')
        if device.get('state') != 'Booted':
            simctl('boot', simulator['id'])
        # Simulator.app has no per-device argument; Xcode's Devices window selects the exact device.
        result = subprocess.run(['/usr/bin/open', simulator['url']], capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise ValueError('Could not open Xcode Devices: ' + result.stderr.strip()[-2000:])
        return simulator

    def tool_info(self):
        return {'title': self.config['title'], 'launcher': launcher(self.config),
                'modules': [item['pattern'] for item in self.config['modules']]}

    def file(self, file_id, iteration=None):
        return next((file for file in self.view(iteration)[0] if file['id'] == file_id), None)

    def file_lines(self, file_id, iteration=None):
        # Full text of both sides lets the page expand unchanged context around hunks.
        file = self.file(file_id, iteration)
        if file is None:
            raise ValueError('Unknown file')
        if file['binary'] or file['limited']:
            return {'old': [], 'new': []}
        blobs = self.view(iteration)[1][file['id']]
        return {side: blobs[side].decode(errors='replace').splitlines() for side in ('old', 'new')}

    def definition_index(self):
        with self.lock:
            if self.definitions is not None:
                return self.definitions
        index = {}
        if self.repo.exists():
            # The worktree, including untracked files, matches what the review shows on the new side.
            output = self.git('grep', '-n', '-I', '-E', '--untracked', '--null',
                              r'(class|struct|enum|protocol|actor|typealias)[[:space:]]+[A-Z]', '--', '*.swift', check=False)
            for line in output.splitlines():
                parts = line.split('\0', 2)
                if len(parts) != 3 or not parts[1].isdigit():
                    continue
                match = SWIFT_DECLARATION.match(parts[2])
                if match:
                    index.setdefault(match[2], []).append({'path': parts[0], 'line': int(parts[1]), 'kind': match[1]})
        with self.lock:
            self.definitions = index
        return index

    def definition(self, name):
        if not isinstance(name, str) or not re.fullmatch(r'[A-Z]\w{0,200}', name):
            raise ValueError('Unknown type name')
        return {'name': name, 'locations': self.definition_index().get(name, [])}

    def source(self, path):
        # Only files Git would show (tracked or untracked but not ignored) are readable.
        if not isinstance(path, str) or not path or path.startswith('/') or '\0' in path or not self.repo.exists():
            raise ValueError('Unknown source file')
        listed = self.git('ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', ':(literal)' + path, binary=True).split(b'\0')
        if path.encode('utf-8', 'surrogateescape') not in listed or not (self.repo / path).is_file():
            raise ValueError('Unknown source file')
        blob = self.work_blob(path)
        if len(blob) > MAX_TEXT or b'\0' in blob[:8192]:
            raise ValueError('Source file is too large or binary to preview')
        return {'path': path, 'lines': blob.decode(errors='replace').splitlines()}

    def search(self, query, scope='diff', match_case=False, iteration=None):
        if not isinstance(query, str) or not 1 <= len(query) <= 200 or '\0' in query or '\n' in query:
            raise ValueError('Search for 1–200 characters on one line')
        if scope not in ('diff', 'files', 'project'):
            raise ValueError('Search scope must be diff, files or project')
        needle = query if match_case else query.lower()
        found = (lambda text: needle in text) if match_case else (lambda text: needle in text.lower())
        results = []
        if scope in ('diff', 'files'):
            files, blobs = self.view(iteration)[:2]
            for file in sorted(files, key=lambda file: file['path']):
                if file['binary'] or file['limited']:
                    continue
                # Diff searches the hunks as displayed; files searches complete new contents. Deleted lines exist only on the old side.
                if scope == 'diff':
                    matches = [('old', row['old'], row['text']) if row['type'] == 'delete' else ('new', row['new'], row['text'])
                               for row in file['rows'] if row['type'] != 'hunk' and found(row['text'])]
                else:
                    new = blobs[file['id']]['new'].decode(errors='replace').splitlines()
                    matches = [('new', number, text) for number, text in enumerate(new, 1) if found(text)]
                    matches += [('old', row['old'], row['text']) for row in file['rows'] if row['type'] == 'delete' and found(row['text'])]
                results += [{'path': file['path'], 'file': file['id'], 'side': side, 'line': number, 'text': text[:500]} for side, number, text in matches]
        elif self.repo.exists():
            output = self.git('grep', '-n', '-I', '-F', '--untracked', '--null', *(() if match_case else ('-i',)), '-e', query, check=False)
            for line in output.splitlines():
                parts = line.split('\0', 2)
                if len(parts) == 3 and parts[1].isdigit():
                    results.append({'path': parts[0], 'line': int(parts[1]), 'text': parts[2][:500]})
                if len(results) > MAX_SEARCH_RESULTS:
                    break
        return {'query': query, 'scope': scope, 'results': results[:MAX_SEARCH_RESULTS], 'truncated': len(results) > MAX_SEARCH_RESULTS}

    def callers(self, name):
        # Text matching cannot resolve overloads or receivers; the page ranks call sites nearest the declaration first.
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z_]\w{0,200}', name):
            raise ValueError('Unknown method name')
        results = []
        if self.repo.exists():
            output = self.git('grep', '-n', '-I', '-E', '--untracked', '--null', rf'(^|[^[:alnum:]_]){name}[[:space:]]*[({{]', '--', '*.swift', check=False)
            declaration = re.compile(rf'\bfunc\s+{name}\b')
            for line in output.splitlines():
                parts = line.split('\0', 2)
                if len(parts) != 3 or not parts[1].isdigit() or declaration.search(parts[2]) or parts[2].lstrip().startswith('//'):
                    continue
                results.append({'path': parts[0], 'line': int(parts[1]), 'text': parts[2].strip()[:500]})
                if len(results) > MAX_SEARCH_RESULTS:
                    break
        return {'name': name, 'results': results[:MAX_SEARCH_RESULTS], 'truncated': len(results) > MAX_SEARCH_RESULTS}

    def snapshot(self, name):
        # A private index writes immutable Git trees without staging or committing branch changes.
        with tempfile.TemporaryDirectory(dir=self.store) as directory:
            env = {**os.environ, 'GIT_INDEX_FILE': str(Path(directory) / 'index')}
            def git(*args):
                result = subprocess.run(['git', *args], cwd=self.repo, env=env, capture_output=True, text=True, timeout=60)
                if result.returncode:
                    raise ValueError(result.stderr.strip())
                return result.stdout.strip()
            git('read-tree', 'HEAD')
            git('add', '--all')
            tree = git('write-tree')
            ref = f'refs/{self.config["name"]}/{self.session_id}/{name}'
            git('update-ref', ref, tree)
            return tree

    def origin_agent(self):
        saved = read_json(self.store / f'{self.session_id}.json', self.session)
        return saved.get('agent') or ({'provider': 'codex', 'sessionId': saved['threadId']}
                                     if saved.get('threadId') else None)

    def record_agent(self):
        agent = detect_agent(self.config['name'])
        if agent:
            self.session['agent'] = agent
            self.session['threadId'] = agent['sessionId'] if agent['provider'] == 'codex' else None
            self.save_session('agent', 'threadId')

    def begin_iteration(self, iteration, request):
        if iteration in ('full', 'thread') or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', iteration) or not isinstance(request, str) or not 1 <= len(request.strip()) <= 10000:
            raise ValueError('Provide an iteration ID and a user-request summary of at most 10000 characters')
        pending = self.session.get('pendingIteration')
        if pending:
            if pending['id'] == iteration:
                return  # Repeated tool calls within one interaction do not add iterations.
            raise ValueError('Finish the pending interaction before beginning another')
        if any(i['id'] == iteration for i in self.session['iterations']):
            return
        self.record_agent()
        self.session['pendingIteration'] = {'id': iteration, 'request': request.strip(), 'before': self.snapshot('pending-' + iteration),
                                           'agent': self.origin_agent(), 'startedAt': datetime.now(timezone.utc).isoformat()}
        self.save_session('pendingIteration')

    def finish_iteration(self, iteration, summary, title, description):
        self.validate_message(title, description)
        if not isinstance(summary, str) or not 1 <= len(summary.strip()) <= 10000:
            raise ValueError('Provide a completion summary of at most 10000 characters')
        existing = next((i for i in self.session['iterations'] if i['id'] == iteration), None)
        pending = self.session.get('pendingIteration')
        if (not pending or pending['id'] != iteration) and not existing:
            raise ValueError('Begin the user interaction before making changes; no baseline was recorded')
        if pending and pending['id'] != iteration:
            raise ValueError('A different user interaction is pending')
        after = self.snapshot('iteration-' + iteration)
        item = {**(existing or pending), 'number': existing['number'] if existing else len(self.session['iterations']) + 1,
                'after': after, 'summary': summary.strip(), 'finishedAt': datetime.now(timezone.utc).isoformat()}
        item.setdefault('agent', self.origin_agent())
        if existing:
            self.session['iterations'][self.session['iterations'].index(existing)] = item
        else:
            self.session['iterations'].append(item)
        self.session.pop('pendingIteration', None)
        self.session['mergeDraft'] = {'title': title.strip(), 'description': description.strip()}
        self.historical.pop(iteration, None)
        self.historical.pop('thread', None)
        self.save_session('iterations', 'pendingIteration', 'mergeDraft')

    @staticmethod
    def validate_message(title, description):
        if not isinstance(title, str) or not re.fullmatch(r'(feat|fix|chore|refactor|perf|test|docs|build|ci|style|revert)\([a-z0-9-]+\)!?: [^\r\n]{1,220}', title):
            raise ValueError('Provide a Conventional Commit title, e.g. feat(review): add local review tool')
        if not isinstance(description, str) or not 1 <= len(description.strip()) <= 20000:
            raise ValueError('Provide a description of the final change and its validation (at most 20000 characters)')

    def save_session(self, *fields):
        # The CLI records interactions while the browser can still save comments.
        path = self.store / f'{self.session_id}.json'
        with (self.store / f'{self.session_id}.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            latest = read_json(path, dict(self.session))
            for key in fields or ('comments', 'viewed'):
                if key in self.session:
                    latest[key] = self.session[key]
                else:
                    latest.pop(key, None)
            write_json(path, latest)
            self.session = latest

    def review_time(self):
        # Read the shared store so other tabs and CLI updates remain visible.
        saved = read_json(self.store / f'{self.session_id}.json', self.session)
        scopes = saved.get('reviewTime', {})
        by_scope = {scope: sum(clients.values()) for scope, clients in scopes.items()}
        return {'totalMs': sum(by_scope.values()), 'byScope': by_scope}

    def record_review_time(self, client, scope, elapsed_ms, intervals=None):
        if (not isinstance(client, str) or not re.fullmatch(r'[a-f0-9-]{36}', client)
                or not isinstance(scope, str) or type(elapsed_ms) is not int
                or not 0 <= elapsed_ms <= 2**53 - 1):
            raise ValueError('Invalid active review time')
        if intervals is not None and (not isinstance(intervals, list) or len(intervals) > 500 or not all(
                isinstance(i, list) and len(i) == 2 and all(type(t) is int and 0 <= t <= 2**53 - 1 for t in i) and i[0] <= i[1]
                for i in intervals)):
            raise ValueError('Invalid active review intervals')
        path = self.store / f'{self.session_id}.json'
        with (self.store / f'{self.session_id}.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            latest = read_json(path, self.session)
            if scope not in ('full', 'thread') and not any(i['id'] == scope for i in latest.get('iterations', [])):
                raise ValueError('Unknown review time scope')
            clients = latest.setdefault('reviewTime', {}).setdefault(scope, {})
            # Cumulative counters make retries and out-of-order requests idempotent.
            if intervals is not None and elapsed_ms >= clients.get(client, 0):
                # Epoch-millisecond stretches explain each counter; only the newest cumulative list is kept.
                latest.setdefault('reviewTimeIntervals', {}).setdefault(scope, {})[client] = intervals
            clients[client] = max(clients.get(client, 0), elapsed_ms)
            write_json(path, latest)
            self.session = latest
        return self.review_time()

    def update_settings(self, settings):
        if not settings or set(settings) - set(DEFAULTS):
            raise ValueError('Unknown or missing setting')
        # Reviews in separate worktrees share defaults; a single preference must not overwrite the others.
        with (self.store / 'settings.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            previous = {**DEFAULTS, **read_json(self.store / 'settings.json', {})}
            settings = {**previous, **settings}
            self.validate_settings(settings)
            write_json(self.store / 'settings.json', settings)
        self.settings = settings
        if settings['rubric'] == previous['rubric']:
            return
        self.historical.clear()
        for file in self.files:
            file.update(score=fallback_score(file['path'], self.config), scorer='Fallback')
            file.pop('signals', None)
        self.apply_scores()
        self.start_ranking()

    @staticmethod
    def validate_settings(settings):
        if settings['diffMode'] not in ('split', 'unified'):
            raise ValueError('Diff mode must be split or unified')
        if any(type(settings[key]) is not bool for key in ('hideLocalization', 'hideTests', 'hideViews', 'hideManifests', 'hideGenerated')):
            raise ValueError('Filter flags must be booleans')
        if type(settings['imageScale']) is not int or not 25 <= settings['imageScale'] <= 100:
            raise ValueError('Image scale must be between 25 and 100')
        if not isinstance(settings['exclude'], list) or len(settings['exclude']) > 100 or any(not isinstance(p, str) or len(p) > 500 for p in settings['exclude']):
            raise ValueError('Provide at most 100 exclusion globs')
        if not isinstance(settings['rubric'], str) or not 1 <= len(settings['rubric']) <= 6000:
            raise ValueError('Importance instructions must be 1–6000 characters')

    def start_ranking(self):
        if not self.auto_rank or not os.environ.get('JEV_API_KEY'):
            return
        if self.ranking['status'] == 'running':
            self.rank_again = True
            return
        self.ranking = {'status': 'running', 'fallbacks': 0}
        threading.Thread(target=self.rank, daemon=True).start()

    def rank(self):
        key = os.environ.get('JEV_API_KEY')
        if not key:
            raise ValueError('JEV_API_KEY is missing from the review server environment.')
        def evaluate(file):
            with self.lock:
                cache_key = self.score_key(file)
                if cache_key in self.cache:
                    return 0
                rubric = self.settings['rubric']
            if file['kind'] == 'generated':
                return 0  # Regenerated output keeps its fallback score; the source schema carries the change.
            if re.search(r"\b(password|secret|credential|api[_-]?key|dsn)\b", file['patch'], re.I):
                return 1
            if file['limited']:
                return 1  # Never silently judge a truncated patch.
            chunks, chunk = [], ''
            for line in file['patch'].splitlines(keepends=True):
                if len(line.encode()) > 18000:
                    return 1
                if len((chunk + line).encode()) > 18000:
                    chunks.append(chunk)
                    chunk = ''
                chunk += line
            chunks.append(chunk or '[binary or mode-only change; image pixels are reviewed locally]')
            questions = {
                'business': 'Could this change significantly affect business logic, correctness, security, or data integrity and need human attention?',
                'performance': 'Could this change significantly affect app performance, latency, memory, concurrency, or resource use and need human attention?',
                'ui': 'Does this change significantly alter visible behavior, interaction, accessibility, or UX and need human attention? Routine styling and navigation generally score low; lint already covers many presentation conventions.',
            }
            values = dict.fromkeys(questions, 0)
            for index, chunk in enumerate(chunks):
                payload = {'model': 'jev-latest', 'state': {'path': file['path'], 'status': file['status'],
                           'diff': chunk, 'part': index + 1, 'parts': len(chunks), 'category': file['kind']},
                           'questions': {name: {'type': 'noul', 'instructions': instructions + '\nPreferences: ' + rubric + '\nReturn likelihood of significance from 0 to 1. Stay uncertain when context is missing.'} for name, instructions in questions.items()}}
                request = urllib.request.Request('https://api.typesafe.ai/v1/systemone',
                           data=json.dumps(payload).encode(), headers={'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'})
                try:
                    with urllib.request.urlopen(request, timeout=15) as response:
                        result = json.load(response)
                    part_values = {name: result['answers'][name]['noul'] for name in questions}
                    if any(type(v) not in (float, int) or not math.isfinite(v) or not 0 <= v <= 1 for v in part_values.values()):
                        raise ValueError('Invalid score')
                except (OSError, ValueError, KeyError, TypeError):
                    return 1
                values = {name: max(values[name], v) for name, v in part_values.items()}
            with self.lock:
                with (self.store / 'scores.lock').open('a') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    self.cache = {**read_json(self.store / 'scores.json', {}), cache_key: {'score': round(max(values.values()) * 100), 'signals': {name: round(v * 100) for name, v in values.items()}}}
                    write_json(self.store / 'scores.json', self.cache)
                self.apply_scores()
            return 0
        try:
            with ThreadPoolExecutor(max_workers=3) as pool:
                candidates = list({self.score_key(f): f for f in [*self.files, *(f for view in list(self.historical.values()) for f in view[3])]}.values())
                failures = sum(pool.map(evaluate, candidates))
            with self.lock:
                self.ranking = {'status': 'done', 'fallbacks': failures}
                if self.rank_again:
                    self.rank_again = False
                    self.start_ranking()
        except Exception:
            with self.lock:
                self.ranking = {'status': 'done', 'fallbacks': len(self.files)}

    def start_merge(self, revision, title, description):
        with self.lock:
            if revision != self.revision or self.capture()[-1] != revision:
                raise ValueError('Changes or target moved since this review. Refresh and review again.')
            if self.branch == self.target or not self.branch or not self.files:
                raise ValueError('No branch changes to merge')
            if self.git('branch', '--show-current').strip() != self.branch:
                raise ValueError('The checked-out branch changed')
            if self.job['status'] == 'running':
                raise ValueError('Merge already running')
            if any(f['submoduleDirty'] for f in self.files):
                raise ValueError('Commit uncommitted submodule changes inside the submodule, validate and retry this merge request.')
            self.validate_message(title, description)
            if self.git('merge-base', self.target, 'HEAD').strip() != self.target_head:
                raise ValueError('Rebase onto the target, resolve conflicts, validate and retry this merge request.')
            self.job = {'status': 'running', 'log': 'Agent is validating the prepared merge…\n'}
            threading.Thread(target=self.merge, args=(revision, title, description), daemon=True).start()

    def merge_request(self, request_id=None):
        if request_id is None:
            return read_json(self.store / f'{self.session_id}-merge-request.json', None)
        if not re.fullmatch(r'[0-9a-f]{24}', request_id):
            raise ValueError('Invalid merge request ID')
        for path in list(self.store.glob('*-merge-request.json')) + list((self.store / 'queue-history').glob('*.json')):
            request = read_json(path, None)
            if request and request['id'] == request_id:
                return request
        raise ValueError('Unknown merge request')

    def merge_log_path(self, request_id=None):
        request = self.merge_request(request_id)
        if not request or not re.fullmatch(r'[0-9a-f]{24}', request['id']):
            raise ValueError('No matching merge log')
        path = self.store / (request['id'] + '-agent.log')
        if path.is_symlink():
            raise ValueError('Invalid merge log path')
        return path

    def merge_progress(self, request_id=None):
        request = self.merge_request(request_id)
        path = self.merge_log_path(request_id)
        size, head, tail = 0, '', ''
        try:
            with path.open('rb') as log:
                size = os.fstat(log.fileno()).st_size
                head = log.read(16384).decode(errors='replace')
                log.seek(max(0, size - 65536))
                tail = log.read(65536).decode(errors='replace')
        except FileNotFoundError:
            pass  # Delivery has not opened the log yet.
        origin = request.get('agent', {}).get('provider', 'codex' if request.get('threadId') else None)
        worker = re.search(r'^session id: ([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$', head, re.M) if origin == 'codex' else None
        session_id = worker.group(1) if worker else request.get('workerSessionId')
        if not isinstance(session_id, str) or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', session_id):
            session_id = None
        if origin == 'claude' and not session_id:
            for line in head.splitlines():
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if isinstance(event, dict) and event.get('type') == 'system' and event.get('subtype') == 'init':
                    candidate = event.get('session_id', '')
                    if isinstance(candidate, str) and re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', candidate):
                        session_id = candidate
                        break
        # Claude emits newline-delimited events; preserve the raw stream in the downloadable log.
        if origin == 'claude':
            lines = []
            for line in tail.splitlines():
                try:
                    event = json.loads(line)
                except ValueError:
                    lines.append(line)
                    continue
                if not isinstance(event, dict):
                    lines.append(line)
                    continue
                for block in event.get('message', {}).get('content', []) if isinstance(event.get('message'), dict) else []:
                    if isinstance(block, dict) and block.get('type') == 'text':
                        lines.append(block.get('text', ''))
                    elif isinstance(block, dict) and block.get('type') in ('tool_use', 'tool_result'):
                        lines.append(block.get('name', 'Tool result') + '\n' + json.dumps(block.get('input', block.get('content')), ensure_ascii=False, indent=2))
                if event.get('result'):
                    lines.append(str(event['result']))
                if event.get('type') == 'system' and event.get('subtype') == 'init':
                    lines.append('Claude session: ' + str(event.get('session_id', '')))
            tail = '\n'.join(lines)
        tail = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', tail)
        resume_target = session_id
        if origin == 'claude' and session_id:
            history = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude') / 'projects'
            transcripts = [p for p in history.glob('*/' + session_id + '.jsonl') if p.is_file() and not p.is_symlink()]
            if transcripts:
                resume_target = str(max(transcripts, key=lambda p: p.stat().st_mtime))
        return {'id': request['id'], 'log': tail, 'truncated': size > 65536,
                'provider': origin, 'workerSessionId': session_id,
                'resumeTarget': resume_target,
                'resumeCommand': shlex.join(['claude', '--resume', resume_target]) if origin == 'claude' and resume_target else None,
                'workerThreadId': worker.group(1) if worker else None,
                'running': request['status'] == 'pending' or (request['status'] == 'working' and process_alive(request.get('mergePid'))) or (request.get('delivery') == 'started' and not path.with_name(request['id'] + '-agent-response.txt').exists())}

    def open_claude_conversation(self, request_id=None):
        request = self.merge_request(request_id)
        progress = self.merge_progress(request_id)
        if progress['provider'] != 'claude' or not progress['workerSessionId']:
            raise ValueError('No Claude worker session is available yet')
        if progress['running']:
            raise ValueError('The merge is still running. Follow its live output here; open the conversation after it finishes.')
        if sys.platform != 'darwin':
            raise ValueError('Native conversation opening requires macOS. Use the Copy resume command button.')
        cli = request['agent'].get('cli') or shutil.which('claude')
        if not cli or not Path(cli).is_file():
            raise ValueError('Claude CLI is unavailable. Use the Copy resume command button.')
        # The original worktree may have been removed by a successful merge.
        repo = next((Path(request[key]) for key in ('repo', 'mergeRoot') if Path(request[key]).is_dir()), None)
        if repo is None:
            raise ValueError('The session repository is unavailable. Use the Copy resume command button.')
        env = dict(os.environ)
        markers = ('CLAUDECODE', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_PID',
                   'CODEX_THREAD_ID', 'CODEX_SESSION_ID', 'CODEX_APP_TOOLS_PIPE_PATH', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE')
        for name in markers:
            env.pop(name, None)
        help_result = subprocess.run([cli, '--help'], capture_output=True, text=True, timeout=15, env=env)
        if help_result.returncode:
            raise ValueError(help_result.stderr.strip() or 'Cannot inspect Claude CLI capabilities')
        if Path(request['repo']).is_dir() and re.search(r'^\s*--desktop(?:\s|$)', help_result.stdout, re.M):
            result = subprocess.run([cli, '--desktop', '--resume', progress['workerSessionId']],
                                    cwd=repo, capture_output=True, text=True, timeout=15, env=env)
            destination = 'Claude Desktop'
        else:
            command = self.store / (request['id'] + '-resume-claude.command')
            script = '#!/bin/sh\ncd ' + shlex.quote(str(repo)) + ' || exit 1\n'
            script += 'unset ' + ' '.join(markers) + '\n'
            script += 'exec ' + shlex.join([str(Path(cli).resolve()), '--resume', progress['resumeTarget']]) + '\n'
            # Replace any stale script or symlink rather than following it.
            command.unlink(missing_ok=True)
            command.write_text(script)
            command.chmod(0o700)
            result = subprocess.run(['/usr/bin/open', '-a', 'Terminal', str(command)], capture_output=True, text=True, timeout=15)
            destination = 'Claude in Terminal'
        if result.returncode:
            raise ValueError(result.stderr.strip() or f'Could not open {destination}')
        return {'destination': destination}

    @contextmanager
    def merge_request_lock(self):
        with (self.store / f'{self.session_id}-merge-request.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def merge_queue(self):
        return merge_queue(self.store)

    def request_merge(self, revision, title, description):
        with self.merge_request_lock():
            return self.save_merge_request(revision, title, description)

    def save_merge_request(self, revision, title, description):
        branch = self.branch
        if self.git('branch', '--show-current').strip() != self.branch:
            raise ValueError('The checked-out branch changed')
        self.refresh()
        if self.branch != branch or self.git('branch', '--show-current').strip() != branch:
            raise ValueError('The checked-out branch changed')
        if revision != self.approval_revision():
            raise ValueError('Reviewed files changed. Refresh and review the updated diff before approving.')
        if not self.branch or self.branch == self.target or not self.files:
            raise ValueError('No branch changes to merge')
        if any(file['submoduleDirty'] for file in self.files):
            raise ValueError('Commit uncommitted submodule changes inside the submodule, then refresh and approve.')
        if self.git('branch', '--show-current').strip() != self.branch:
            raise ValueError('The checked-out branch changed')
        if not isinstance(title, str) or len(title) > 250 or not isinstance(description, str) or len(description) > 20000:
            raise ValueError('Invalid merge notes')
        previous = self.merge_request()
        if previous and previous['status'] in ('pending', 'working'):
            expected = revision if 'reviewedRevision' in previous else self.revision
            if previous.get('reviewedRevision', previous['revision']) != expected:
                raise ValueError('Withdraw the previous approval before approving a different diff')
            return previous
        agent = self.origin_agent()
        if not agent or agent.get('provider') not in ('codex', 'claude'):
            raise ValueError(f'No originating agent detected. Start {launcher(self.config)} from your Codex or Claude session first.')
        if previous:
            write_json(self.store / 'queue-history' / (previous['id'] + '.json'), previous)
        request = {'id': secrets.token_hex(12), 'status': 'pending', 'delivery': 'not_sent',
                   'requestedAt': datetime.now(timezone.utc).isoformat(), 'revision': self.revision, 'reviewedRevision': revision,
                   'branch': self.branch, 'target': self.target, 'head': self.head, 'targetHead': self.target_head,
                   'repo': str(self.repo), 'mergeRoot': str(self.common.parent), 'sessionId': self.session_id,
                   'threadId': agent.get('sessionId') if agent['provider'] == 'codex' else None,
                   'agent': agent,
                   'title': title.strip(), 'description': description.strip(),
                   'comments': self.session['comments'], 'summary': 'Approval saved. Waiting for an agent.'}
        # A private commit exposes the complete approved diff, including uncommitted files.
        tree = self.snapshot('queue-' + request['id'])
        request['snapshotBase'] = self.git('merge-base', self.target, 'HEAD').strip()
        request['snapshotCommit'] = self.git('commit-tree', tree, '-p', request['snapshotBase'],
                                           '-m', 'Approved pending changes for ' + self.branch).strip()
        request['snapshotRef'] = f'refs/{self.config["name"]}/queue/' + request['id']
        self.git('update-ref', request['snapshotRef'], request['snapshotCommit'])
        request['changedPaths'] = [f['path'] for f in self.files]
        snapshot_files = self.capture(before=request['snapshotBase'], after=request['snapshotCommit'])[3]
        if (self.capture()[-1] != self.revision or
                [(f['path'], f['fingerprint']) for f in snapshot_files] !=
                [(f['path'], f['fingerprint']) for f in sorted(self.files, key=lambda f: f['path'])]):
            raise ValueError('Files changed while saving the pending snapshot. Refresh and review before approving.')
        path = self.store / f'{self.session_id}-merge-request.json'
        request['path'] = str(path)
        cli = launcher(self.config)
        request['prompt'] = (f'The user approved the full local review and delegated completing the local merge. '
            f'Read merge request {request["id"]} at {path} and verify it is still pending. '
            'Your worker has reserved the repository merge queue before starting this agent. Keep that reservation through preparation, validation and cleanup. '
            'First fetch the merge target’s configured upstream if it has one. Integrate its latest commits into the local target '
            'without dropping local commits or disturbing unrelated working changes, then rebase this worktree branch onto that latest target. '
            'If the target has no configured upstream, use its latest local commit. Do not run git pull on the feature branch. '
            'Resolve conflicts yourself, preserving the feature intent and unrelated changes. After updating the branch, inspect the complete diff and current review comments. '
            'Handle release readiness and required validation yourself: address actionable comments, fix failing checks, '
            'rebase onto the target and resolve conflicts as needed. Unresolved comment flags are not merge blockers. '
            'This approval authorizes corrections needed to finish the existing task; do not ask for fresh approval for fixes or rebasing. '
            'Do not stop at a list of tests, comments or rebase work for the user. Keep fixing and retrying until merged. '
            'Preserve unrelated edits, do not add unrelated features, and do not weaken tests or bypass validation to make checks pass. '
            'Execution runs the configured merge checks and the Worktrunk merge hooks on the prepared branch. '
            'Do not run the same validation immediately beforehand on unchanged content just to run it again; '
            'run extra checks only for an actual correction or unresolved concern. '
            'Before each attempt, verify the request is still pending and the branch and target are the intended ones. '
            'A withdrawn approval must never merge. Use Worktrunk hooks and default cleanup; do not push. '
            'Do not open review or queue pages in any browser, including Chrome, the Codex or Claude built-in browser and Computer Use; '
            'the user opens them manually, and the CLI commands below provide the approval, comments and merge status. '
            f'Use {cli} --base {self.target} --merge-request {request["id"]} to inspect the approval and latest comments. '
            f'After validation, use {cli} --base {self.target} --execute-merge-request {request["id"]} '
            '--title "<final Conventional Commit title>" --description-file /absolute/path/to/final-description.txt. '
            'Prepare one sensible commit describing the complete final behavior and validation. '
            'If execution fails, inspect its log, correct the cause and execute the SAME request again; the approval remains pending. '
            'Execution can outlast one shell command. If you run it in the background, keep polling '
            f'{cli} --base {self.target} --merge-request {request["id"]} until its status is merged or pending, '
            'and never end your turn while it runs: ending the turn stops the merge. '
            'Work in this existing worktree; do not create another. '
            f'Record this approval as one user interaction named merge-{request["id"]}; finish/update its snapshot after corrections '
            'and before merging removes the worktree. Internal retries are not new user interactions. '
            'Only report a blocker if completion truly requires unavailable credentials, an external service, or a decision outside this task. '
            'Report success only after the saved request status is merged.'
            + (' ' + self.config['merge']['instructions'].strip() if self.config['merge']['instructions'].strip() else ''))
        write_json(path, request)
        self.notify_merge_request(request)
        return request

    def notify_merge_request(self, request):
        try:
            with (self.store / f'{request["id"]}-delivery.log').open('a') as log:
                subprocess.Popen([sys.executable, str(AGENT_RUNTIME / 'agent.py'), request['path']],
                                 stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
        except OSError as error:
            request.update(status='blocked', delivery='failed', summary=f'Approval saved, but agent delivery failed: {error}. Resume the saved request from its worktree.')
            write_json(Path(request['path']), request)

    def cancel_merge_request(self, request_id):
        with self.merge_request_lock():
            request = self.merge_request()
            if not request or request['id'] != request_id or request['status'] != 'pending':
                raise ValueError('Only a pending approval can be withdrawn')
            request.update(status='cancelled', summary='Approval withdrawn. The agent must not merge this request.')
            write_json(Path(request['path']), request)

    def review_handoff(self):
        handoff = read_json(self.store / f'{self.session_id}-review-handoff.json', None)
        if handoff and handoff['status'] == 'running' and handoff.get('workerPid') and not process_alive(handoff['workerPid']):
            handoff.update(status='failed', summary=handoff.get('summary') or 'The agent stopped before reporting back. Copy the request into its chat.')
        return handoff

    def handoff_blocker(self):
        """Why the reviewer cannot send review comments to the agent right now, if anything stops it."""
        if not self.worktree_available():
            return 'Only the live worktree review can be sent to its agent.'
        agent = self.origin_agent()
        if not agent or agent.get('provider') not in ('codex', 'claude') or not agent.get('sessionId'):
            return f'No originating agent conversation detected. Start {launcher(self.config)} from your Codex or Claude session first.'
        if read_json(self.store / f'{self.session_id}.json', self.session).get('pendingIteration'):
            return 'The agent is still working on its current request. Send the review after it finishes its turn.'
        request = self.merge_request()
        if request and request['status'] in ('pending', 'working'):
            return 'A merge is requested; the merge agent receives every comment.'
        handoff = self.review_handoff()
        if handoff and handoff['status'] == 'running':
            return 'The agent is still handling the previous review.'
        return None

    def handoff_state(self):
        comments = read_json(self.store / f'{self.session_id}.json', self.session).get('comments', [])
        handoff = self.review_handoff()
        return {'last': {k: v for k, v in handoff.items() if k != 'prompt'} if handoff else None, 'blocker': self.handoff_blocker(),
                'unsent': sum(not c['resolved'] and not c.get('sentAt') for c in comments)}

    def send_review(self, note):
        """Resume the conversation that wrote the change with the reviewer's new comments."""
        if not isinstance(note, str) or len(note) > 10000:
            raise ValueError('The note for the agent must be at most 10000 characters')
        if blocker := self.handoff_blocker():
            raise ValueError(blocker)
        comments = [c for c in self.session['comments'] if not c['resolved'] and not c.get('sentAt')]
        if not comments and not note.strip():
            raise ValueError('No new unresolved comments to send. Add a comment or a note for the agent.')
        current = {f['path']: f['fingerprint'] for f in self.files}
        def location(comment):
            where = 'whole file' if comment['side'] == 'file' else f"{comment['side']} side, line {comment['line']}" + (
                f"–{comment['endLine']}" if comment.get('endLine', comment['line']) != comment['line'] else '')
            if comment.get('scope', 'full') != 'full':
                where += ', reviewed in ' + ('this thread' if comment['scope'] == 'thread' else f"interaction {comment['scope']}")
            if current.get(comment['path']) != comment['fingerprint']:
                where += ', written against an earlier version of the file'
            return f"- [{comment['id']}] {comment['path']} ({where})\n" + '\n'.join('  ' + line for line in comment['text'].splitlines())
        cli = launcher(self.config)
        agent = self.origin_agent()
        handoff = {'id': secrets.token_hex(12), 'status': 'running', 'sentAt': datetime.now(timezone.utc).isoformat(),
                   'agent': agent, 'repo': str(self.repo), 'branch': self.branch, 'target': self.target,
                   'comments': [c['id'] for c in comments], 'note': note.strip(), 'summary': ''}
        handoff['prompt'] = (f'The user finished a review pass of branch {self.branch} (merging into {self.target}) in {self.repo} '
            'and sent you their review feedback. Handle it as if they had typed it in this conversation: address each actionable comment '
            'in this worktree. Treat this as one new user interaction and follow the repository agent instructions, including '
            f'{cli} --base {self.target} --begin-iteration <new id> --request "<summary>" before changing files, the usual validation, and '
            f'{cli} --base {self.target} --finish-iteration <same id> with an updated title and description afterwards. '
            'Line numbers refer to the old or new side of the reviewed diff. If a comment asks a question or you disagree with it, '
            'answer it instead of changing code. Do not merge, approve or request a merge, and do not open review or queue pages '
            'in any browser; the user opens them. End with a short reply to each comment, by its ID.\n\n'
            + (f'Reviewer note:\n{note.strip()}\n\n' if note.strip() else '')
            + ('Review comments:\n' + '\n'.join(location(c) for c in comments) if comments else 'No line comments.') + '\n')
        path = self.store / f'{self.session_id}-review-handoff.json'
        handoff['path'] = str(path)
        with path.with_suffix('.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            write_json(path, handoff)
            try:
                handoff['workerPid'] = self.launch_review_worker(path, handoff['id'])
            except OSError as error:
                handoff.update(status='failed', summary=f'Could not start the agent: {error}. Copy the request into its chat.')
            write_json(path, handoff)
        if handoff['status'] == 'running':
            for comment in comments:
                comment.update(sentAt=handoff['sentAt'], handoff=handoff['id'])
            self.save_session('comments')
        return handoff

    def launch_review_worker(self, path, handoff_id):
        with (self.store / f'{handoff_id}-review-delivery.log').open('a') as log:
            return subprocess.Popen([sys.executable, str(AGENT_RUNTIME / 'agent.py'), '--review', str(path)],
                                    stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True).pid

    def recover_interrupted_merge(self, request):
        """Return a working approval to pending when the process running its attempt has exited."""
        if request and request['status'] == 'working' and not process_alive(request.get('mergePid')):
            request.update(status='pending', summary='The previous merge attempt stopped before finishing because its process '
                           'exited. Inspect the worktree, validate and execute the same request again.', mergePid=None)
            write_json(Path(request['path']), request)
        return request

    def execute_merge_request(self, request_id, title, description):
        with self.merge_request_lock():
            request = self.recover_interrupted_merge(self.merge_request())
            if not request or request['id'] != request_id or request['status'] != 'pending':
                raise ValueError('No matching pending approval')
            if request.get('workerPid') and not process_alive(request['workerPid']):
                request.update(workerPid=None)
                write_json(Path(request['path']), request)
        with queue_slot(self.store, request_id):
            self.execute_queued_merge(request_id, title, description)

    def execute_queued_merge(self, request_id, title, description):
        with self.merge_request_lock():
            request = self.recover_interrupted_merge(self.merge_request())
            if not request or request['id'] != request_id or request['status'] != 'pending':
                raise ValueError('No matching pending approval')
            if self.git('branch', '--show-current').strip() != request['branch'] or self.target != request['target']:
                raise ValueError('The approved branch or target changed')
            # Approval covers completing the task; freeze the agent's prepared content for this attempt.
            self.refresh()
            self.merge_backup_head = request['head']
            self.start_merge(self.revision, title, description)
            request.update(status='working', summary='The agent is validating and merging the prepared changes.',
                           preparedRevision=self.revision, mergePid=os.getpid())
            write_json(Path(request['path']), request)
        while self.job['status'] == 'running':
            time.sleep(.1)
        with self.merge_request_lock():
            request = self.merge_request()
            request.update(status='merged' if self.job['status'] == 'merged' else 'pending',
                           summary=self.job['log'][-10000:])
            if request['status'] == 'merged':
                request.update(finishedAt=datetime.now(timezone.utc).isoformat(), title=title, description=description)
            write_json(Path(request['path']), request)
        if request['status'] != 'merged':
            raise ValueError('Merge attempt failed; fix the cause and retry the same request: ' + request['summary'])

    def command(self, args):
        with subprocess.Popen(args, cwd=self.repo, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, stdin=subprocess.DEVNULL, env={**os.environ, 'NO_COLOR': '1'}) as process:
            for line in process.stdout:
                with self.lock:
                    self.job['log'] = (self.job['log'] + line)[-100000:]
            if process.wait():
                raise ValueError(f'Command failed: {args[0]} (see log)')

    def merge(self, revision, title, description):
        try:
            for check in self.config['merge']['checks']:
                if any(re.search(pattern, f['path']) for pattern in check.get('paths', ['']) for f in self.files):
                    self.command(check['command'])
            # Freeze reviewed content again after validation, before touching the index.
            if self.capture()[-1] != revision:
                raise ValueError('Files changed during validation. Inspect the changes, validate and retry the same request.')
            if self.git('branch', '--show-current').strip() != self.branch:
                raise ValueError('The checked-out branch changed')
            self.command(['git', 'add', '--all'])
            if self.capture()[-1] != revision:
                raise ValueError('Files changed while staging. Merge stopped; staged changes remain available.')
            result = subprocess.run(['git', 'diff', '--quiet'], cwd=self.repo)
            if result.returncode:
                raise ValueError('Unstaged changes appeared during approval. Merge stopped.')
            self.validate_message(title, description)
            message = self.store / f'{self.session_id}-merge-message.txt'
            message.write_text(title.strip() + '\n\n' + description.strip() + '\n')
            # Preserve the original tip before making the single final commit; iteration trees are separate.
            self.command(['git', 'update-ref', 'refs/wt-backup/' + self.branch, getattr(self, 'merge_backup_head', self.head)])
            self.command(['git', 'reset', '--soft', self.target_head])
            self.command(['git', 'commit', '--file', str(message)])
            now = self.capture()
            if [(f['path'], f['fingerprint']) for f in now[3]] != [(f['path'], f['fingerprint']) for f in sorted(self.files, key=lambda f: f['path'])]:
                raise ValueError('Commit hooks changed prepared files. Inspect the changes, validate and retry the same request.')
            # The agent prepares rebases; Worktrunk runs validation and cleanup on the frozen attempt.
            if self.git('rev-parse', self.target).strip() != self.target_head:
                raise ValueError('Target moved during validation. Rebase, validate and retry the same request.')
            self.command([arg.replace('{target}', self.target) for arg in self.config['merge']['command']])
            self.job['status'] = 'merged'
        except Exception as error:
            with self.lock:
                self.job['status'] = 'failed'
                self.job['log'] += f'\n{error}\n'


class ReviewRegistry:
    def __init__(self, store):
        self.store = store
        self.reviews = {}
        self.lock = threading.RLock()

    def get(self, session_id):
        if not isinstance(session_id, str) or not re.fullmatch(r'[0-9a-f]{24}', session_id):
            raise ValueError('Open a review link with its review identity')
        with self.lock:
            saved = read_json(self.store / 'reviews' / f'{session_id}.json', None)
            if not saved:
                request = next((r for r in queue_requests(self.store) if r.get('sessionId') == session_id), None)
                if not request or not request.get('snapshotCommit'):
                    raise ValueError('Unknown review')
                # Queue approvals predating the shared server already have durable Git snapshots.
                saved = {'sessionId': session_id, 'repo': request['repo'], 'common': str(self.store.parent),
                         'branch': request['branch'], 'target': request['target'], 'head': request['snapshotCommit'],
                         'targetHead': request['snapshotBase'], 'base': request['snapshotBase'], 'tree': request['snapshotCommit']}
                write_json(self.store / 'reviews' / f'{session_id}.json', saved)
            if session_id not in self.reviews:
                # Always start from the saved branch identity, even if the checkout was removed
                # or has since switched to a different branch.
                self.reviews[session_id] = Review(saved['repo'], saved['target'], state_dir=self.store, saved=saved)
            return self.reviews[session_id]


def register_review(review):
    tree = review.snapshot('server-live')
    write_json(review.store / 'reviews' / f'{review.session_id}.json', {
        'sessionId': review.session_id, 'repo': str(review.repo), 'common': str(review.common),
        'branch': review.branch, 'target': review.target, 'head': review.head,
        'targetHead': review.target_head, 'base': review.base, 'tree': tree})


class ReviewServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer resolves the host's FQDN while binding, a reverse DNS lookup that can stall for
        # minutes on some machines. A loopback server never needs it.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, status, data, content_type='application/json'):
        if content_type == 'application/json':
            data = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; img-src 'self' blob:; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        host = f'127.0.0.1:{self.server.server_port}'
        if self.headers.get('Host') != host:
            self.send(403, {'error': 'Invalid host'})
            return False
        if self.path.startswith('/api/'):
            if not secrets.compare_digest(self.headers.get('X-Review-Token', '').encode(), self.server.token.encode()):
                self.send(403, {'error': 'Open the review URL printed by the launcher'})
                return False
            if self.headers.get('Origin') not in (None, 'http://' + host):
                self.send(403, {'error': 'Invalid origin'})
                return False
        return True

    def selected_review(self, url):
        if not hasattr(self.server, 'registry'):
            return self.server.review  # Single-review test servers and older callers.
        query = parse_qs(url.query)
        session_id = query.get('review', [None])[0]
        if not session_id and (merge_id := query.get('merge', [None])[0]):
            request = next((r for r in queue_requests(self.server.registry.store) if r['id'] == merge_id), None)
            session_id = request.get('sessionId') if request else None
        review = self.server.registry.get(session_id)
        with review.lock:
            latest = read_json(review.store / f'{review.session_id}.json', review.session)
            if (latest.get('iterations'), latest.get('pendingIteration'), latest.get('agent')) != (review.session.get('iterations'), review.session.get('pendingIteration'), review.session.get('agent')):
                review.historical.clear()
            review.session = latest
        return review

    def do_GET(self):
        if not self.authorized():
            return
        try:
            url = urlparse(self.path)
            iteration = parse_qs(url.query).get('iteration', [None])[0]
            if url.path == '/' or url.path[1:] in WEB_ASSETS[1:]:
                name = 'index.html' if url.path == '/' else url.path[1:]
                self.send(200, self.server.assets[name], mimetypes.guess_type(name)[0] or 'text/javascript')
                return
            if url.path == '/api/health':
                # Legacy launchers reuse the upgraded server instead of replacing it with old code.
                self.send(200, {'version': getattr(self.server, 'legacy_version', self.server.version),
                                'runtimeVersion': self.server.version})
                return
            if url.path == '/api/queue' and hasattr(self.server, 'registry'):
                self.send(200, {**merge_queue(self.server.registry.store), 'tool': self.server.tool})
                return
            review = self.selected_review(url)
            if url.path == '/api/state':
                self.send(200, review.state(iteration, parse_qs(url.query).get('merge', [None])[0]))
            elif url.path == '/api/queue':
                self.send(200, review.merge_queue())
            elif url.path == '/api/feedback':
                self.send(200, review.feedback())
            elif url.path == '/api/merge-progress':
                self.send(200, review.merge_progress(parse_qs(url.query).get('merge', [None])[0]))
            elif url.path == '/api/merge-log':
                self.send(200, review.merge_log_path(parse_qs(url.query).get('merge', [None])[0]).read_bytes(), 'text/plain; charset=utf-8')
            elif url.path == '/api/file':
                file = review.file(parse_qs(url.query).get('id', [''])[0], iteration)
                if file is None:
                    raise ValueError('Unknown file')
                lines = review.file_lines(file['id'], iteration)
                self.send(200, {'rows': file['rows'], 'limited': file['limited'], 'binary': file['binary'],
                                'oldCount': len(lines['old']), 'newCount': len(lines['new'])})
            elif url.path == '/api/file-lines':
                self.send(200, review.file_lines(parse_qs(url.query).get('id', [''])[0], iteration))
            elif url.path == '/api/definitions':
                self.send(200, {'names': sorted(review.definition_index())})
            elif url.path == '/api/definition':
                self.send(200, review.definition(parse_qs(url.query).get('name', [''])[0]))
            elif url.path == '/api/source':
                self.send(200, review.source(parse_qs(url.query).get('path', [''])[0]))
            elif url.path == '/api/search':
                query = parse_qs(url.query)
                self.send(200, review.search(query.get('q', [''])[0], query.get('scope', ['diff'])[0], query.get('case', [''])[0] == '1', iteration))
            elif url.path == '/api/callers':
                self.send(200, review.callers(parse_qs(url.query).get('name', [''])[0]))
            elif url.path == '/api/image':
                query = parse_qs(url.query)
                file = review.file(query.get('id', [''])[0], iteration)
                side = query.get('side', [''])[0]
                if file is None or not file['image'] or side not in ('old', 'new'):
                    raise ValueError('Unknown image')
                blob = review.view(iteration)[1][file['id']][side]
                if not blob:
                    self.send(404, {'error': 'No image on this side'})
                elif not (blob.startswith(b'\x89PNG\r\n\x1a\n') or blob.startswith(b'\xff\xd8\xff') or (blob.startswith(b'RIFF') and blob[8:12] == b'WEBP')):
                    self.send(422, {'error': 'Image unavailable. A Git LFS object may be missing locally; run git lfs pull.'})
                else:
                    self.send(200, blob, mimetypes.guess_type(file['path'])[0])
            elif url.path == '/api/export':
                self.send(200, {'branch': review.branch, 'revision': review.revision, **review.session})
            else:
                self.send(404, {'error': 'Not found'})
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            self.send(400, {'error': str(error)})

    def do_POST(self):
        if not self.authorized():
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 100000 or self.headers.get('Content-Type') != 'application/json':
                raise ValueError('Expected bounded JSON request')
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError('Expected an object')
            url = urlparse(self.path)
            route = url.path
            if route == '/api/shutdown' and hasattr(self.server, 'registry'):
                if any(r.job['status'] == 'running' for r in self.server.registry.reviews.values()):
                    raise ValueError('Wait for the merge to finish')
                self.send(200, {'status': 'stopping'})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            review = self.selected_review(url)
            if parse_qs(url.query).get('merge') and route in ('/api/merge', '/api/merge/cancel'):
                raise ValueError('Saved merge views are read-only')
            iteration = parse_qs(url.query).get('iteration', [None])[0]
            scope = iteration or 'full'
            if route == '/api/review-time':
                with review.lock:
                    timing = review.record_review_time(body.get('clientId'), body.get('scope'), body.get('elapsedMs'), body.get('intervals'))
                self.send(200, timing)
                return
            if route == '/api/rank':
                with review.lock:
                    review.start_ranking()
                self.send(200, review.state(iteration, parse_qs(url.query).get('merge', [None])[0]))
                return
            with review.lock:
                if route == '/api/feedback':
                    self.send(200, review.save_feedback(body.get('text'), body.get('file'), iteration))
                    return
                if route == '/api/feedback/status':
                    self.send(200, review.set_feedback_status(body.get('id'), body.get('implemented')))
                    return
                if review.job['status'] == 'running':
                    raise ValueError('Wait for the merge to finish')
                if route == '/api/shutdown':
                    self.send(200, {'status': 'stopping'})
                    threading.Thread(target=self.server.shutdown, daemon=True).start()
                    return
                if route == '/api/simulator':
                    self.send(200, {'simulator': review.open_simulator()})
                    return
                if route == '/api/review/send':
                    if parse_qs(url.query).get('merge'):
                        raise ValueError('Saved merge views are read-only')
                    review.send_review(body.get('note', ''))
                    self.send(200, review.state(iteration))
                    return
                if route == '/api/merge-conversation':
                    self.send(200, review.open_claude_conversation(parse_qs(url.query).get('merge', [None])[0]))
                    return
                if route == '/api/refresh':
                    if review.repo.exists() and review.git('branch', '--show-current').strip() != review.branch:
                        raise ValueError('This checkout now belongs to another branch. The saved review remains available.')
                    review.refresh()
                    if hasattr(self.server, 'registry') and review.repo.exists():
                        register_review(review)
                elif route == '/api/settings':
                    review.update_settings(body)
                elif route == '/api/comment':
                    file = review.file(body.get('file'), iteration)
                    side, line, text = body.get('side'), body.get('line'), body.get('text')
                    end_line = body.get('endLine', line)
                    if file is None or side not in ('old', 'new', 'file') or type(line) is not int or type(end_line) is not int or line < 0 or end_line < line or not isinstance(text, str) or not 1 <= len(text.strip()) <= 10000:
                        raise ValueError('Invalid comment')
                    if body.get('fingerprint') != file['fingerprint']:
                        raise ValueError('File changed in another review tab. Refresh before commenting.')
                    # Expanded context makes every line of a text side commentable, not only diff hunks.
                    count = len(review.file_lines(file['id'], iteration)[side]) if side != 'file' and file['rows'] else 0
                    if (side == 'file' and (line, end_line) != (0, 0)) or (side != 'file' and not 1 <= line <= end_line <= count):
                        raise ValueError('Comment range is outside the file')
                    review.session['comments'].append({'id': secrets.token_hex(8), 'file': file['id'], 'path': file['path'], 'side': side, 'line': line,
                          'endLine': end_line, 'text': text.strip(), 'resolved': False, 'fingerprint': file['fingerprint'], 'scope': scope})
                    review.save_session()
                elif route == '/api/resolve':
                    comment = next((c for c in review.session['comments'] if c['id'] == body.get('id')), None)
                    if comment is None or type(body.get('resolved')) is not bool:
                        raise ValueError('Unknown comment')
                    comment['resolved'] = body['resolved']
                    review.save_session()
                elif route == '/api/viewed':
                    file = review.file(body.get('file'), iteration)
                    if file is None or type(body.get('viewed')) is not bool:
                        raise ValueError('Unknown file')
                    if body.get('fingerprint') != file['fingerprint']:
                        raise ValueError('File changed in another review tab. Refresh before marking Viewed.')
                    if body['viewed']:
                        review.session['viewed'][scope + ':' + file['id']] = file['fingerprint']
                    else:
                        review.session['viewed'].pop(scope + ':' + file['id'], None)
                        if scope == 'full':
                            review.session['viewed'].pop(file['id'], None)
                    review.save_session()
                elif route == '/api/merge':
                    review.request_merge(body.get('revision'), body.get('title', ''), body.get('description', ''))
                elif route == '/api/merge/cancel':
                    review.cancel_merge_request(body.get('id'))
                else:
                    self.send(404, {'error': 'Not found'})
                    return
            self.send(200, review.state(iteration, parse_qs(url.query).get('merge', [None])[0]))
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            self.send(400, {'error': str(error)})


def main():
    global AGENT_RUNTIME
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--base', default='main', help='Local merge target (default: main)')
    parser.add_argument('--serve', action='store_true', help=argparse.SUPPRESS)
    # Review pages are only opened by the user; the flag stays accepted for older commands.
    parser.add_argument('--no-open', action='store_true', help=argparse.SUPPRESS)
    iterations = parser.add_mutually_exclusive_group()
    iterations.add_argument('--begin-iteration', metavar='ID')
    iterations.add_argument('--finish-iteration', metavar='ID')
    iterations.add_argument('--merge-request', metavar='ID', help='Inspect a pending user approval without merging')
    iterations.add_argument('--execute-merge-request', metavar='ID', help='Agent-only: validate and merge a matching approval')
    iterations.add_argument('--feedback', action='store_true', help='List open review tool feedback')
    iterations.add_argument('--queue', action='store_true', help='Print repository merge queue and pending Git snapshots as JSON')
    iterations.add_argument('--queue-page', action='store_true', help='Open the lightweight repository merge queue page')
    iterations.add_argument('--resume-merge-request', metavar='ID', help='Resume an interrupted or blocked approval in its existing worktree')
    iterations.add_argument('--implement-feedback', metavar='ID', action='append', help='Mark review tool feedback implemented (repeatable)')
    iterations.add_argument('--reopen-feedback', metavar='ID', action='append', help='Return review tool feedback to the open inbox (repeatable)')
    parser.add_argument('--request', default='')
    parser.add_argument('--summary', default='')
    parser.add_argument('--title', default='')
    parser.add_argument('--description-file', type=Path)
    args = parser.parse_args()
    if args.base.startswith('-') or not re.fullmatch(r'[A-Za-z0-9_./-]+', args.base):
        parser.error('Use a local branch name for --base')
    root = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=args.repo, capture_output=True, text=True, check=True).stdout.strip()
    common = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
    config = load_config(root)
    store = Path(common) / config['name']
    store.mkdir(parents=True, exist_ok=True)
    metadata = store / 'shared-server.json'
    if args.queue:
        print(json.dumps(merge_queue(store), indent=2))
        return
    if not args.serve:
        review = Review(root, args.base, auto_rank=False)
        if args.resume_merge_request:
            with review.merge_request_lock():
                request = review.merge_request()
                if (not request or request['id'] != args.resume_merge_request or request['status'] not in ('blocked', 'pending', 'working')
                        or process_alive(request.get('workerPid')) or process_alive(request.get('mergePid'))):
                    parser.error('No matching stopped approval to resume')
                if review.branch != request['branch'] or review.target != request['target']:
                    parser.error('The approved branch or target changed')
                request.update(status='pending', delivery='not_sent', workerPid=None, mergePid=None,
                               summary='Approval resumed. Waiting for its queue turn.')
                write_json(Path(request['path']), request)
            review.notify_merge_request(request)
            print('Resumed merge request ' + request['id'])
            return
        if args.feedback or args.implement_feedback or args.reopen_feedback:
            for entry_id in args.implement_feedback or []:
                review.set_feedback_status(entry_id, True)
            for entry_id in args.reopen_feedback or []:
                review.set_feedback_status(entry_id, False)
            changed = (args.implement_feedback or []) + (args.reopen_feedback or [])
            for entry in (e for e in review.feedback()['entries'] if e['id'] in changed or (args.feedback and e['status'] == 'open')):
                print(f"{entry['id']}  {entry['status']:<11}  {entry['createdAt'][:10]}  {entry.get('path') or '-'}\n    {entry['text']}")
            return
        if not args.merge_request and not args.execute_merge_request:
            review.record_agent()
    if args.begin_iteration or args.finish_iteration or args.merge_request or args.execute_merge_request:
        if args.merge_request:
            with review.merge_request_lock():
                request = review.recover_interrupted_merge(review.merge_request())
            if not request or request['id'] != args.merge_request:
                parser.error('No matching merge request')
            print(json.dumps({**request, 'currentRevision': review.revision,
                              'changedSinceApproval': request['revision'] != review.revision, 'currentComments': review.session['comments']}, indent=2))
            return
        if args.execute_merge_request:
            description = args.description_file.read_text() if args.description_file else ''
            review.execute_merge_request(args.execute_merge_request, args.title, description)
            print(review.job['log'])
            return
        if args.begin_iteration:
            review.begin_iteration(args.begin_iteration, args.request)
            print('Recorded baseline for user interaction ' + args.begin_iteration)
            return
        description = args.description_file.read_text() if args.description_file else ''
        review.finish_iteration(args.finish_iteration, args.summary, args.title, description)
    def show_url(url):
        page = 'queue.html' if args.queue_page else ''
        url = url.replace('/#', '/' + page + '?review=' + review.session_id + '#')
        print(url, flush=True)
        if args.finish_iteration:
            print(url.replace('#', '&iteration=' + args.finish_iteration + '#'), flush=True)
    version = digest(b''.join((ASSETS / name).read_bytes() for name in ('server.py', 'agent.py', *WEB_ASSETS)))
    if not args.serve:
        register_review(review)
        # All worktrees serialize launch/restart and reuse one persisted port and token.
        with (store / 'server-launch.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            previous = read_json(metadata, {})
            url = previous.get('url')
            if url:
                try:
                    headers = {'X-Review-Token': url.split('#')[1]}
                    origin = url.split('#')[0]
                    request = urllib.request.Request(origin + 'api/health', headers=headers)
                    with urllib.request.urlopen(request, timeout=2) as response:
                        running = json.load(response)
                    if running.get('runtimeVersion', running['version']) != version:
                        request = urllib.request.Request(origin + 'api/shutdown', data=b'{}',
                            headers={**headers, 'Content-Type': 'application/json'})
                        with urllib.request.urlopen(request, timeout=2):
                            pass
                        url = None
                except (OSError, ValueError, urllib.error.HTTPError):
                    url = None
            if not url:
                with (store / 'shared-server.log').open('a') as log:
                    process = subprocess.Popen([sys.executable, str(ASSETS / 'server.py'), '--serve', '--repo', root, '--base', args.base],
                                               stdout=subprocess.PIPE, stderr=log, start_new_session=True, text=True)
                    url = process.stdout.readline().strip()
                    process.stdout.close()
                    if not url.startswith('http://127.0.0.1:'):
                        raise SystemExit(f'Review server failed; see {log.name}')
            request = urllib.request.Request(url.split('#')[0] + 'api/refresh?review=' + review.session_id, data=b'{}',
                headers={'X-Review-Token': url.split('#')[1], 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=60):
                pass
        show_url(url)
        return
    previous = read_json(metadata, {})
    parsed = urlparse(previous.get('url', ''))
    port = parsed.port if parsed.hostname == '127.0.0.1' else 8732
    for attempt in range(50):
        try:
            server = ReviewServer(('127.0.0.1', port), Handler)
            break
        except OSError:
            if attempt == 49:
                raise ValueError(f'Review port {port} is occupied. Stop its owner and restart; saved links keep this port.')
            time.sleep(.1)
    server.registry = ReviewRegistry(store)
    server.tool = {'title': config['title'], 'launcher': launcher(config)}
    server.token = parsed.fragment or secrets.token_urlsafe(32)
    server.version = version
    server.legacy_version = previous.get('legacyVersion', previous.get('version', version))
    # The shared server must still launch merge workers after its source worktree is removed.
    AGENT_RUNTIME = store / 'runtime' / version
    AGENT_RUNTIME.mkdir(parents=True, exist_ok=True)
    for name in ('server.py', 'agent.py'):
        (AGENT_RUNTIME / name).write_bytes((ASSETS / name).read_bytes())
    # Keep assets in memory so merging this tool's own worktree can remove it safely.
    server.assets = {name: (ASSETS / name).read_bytes() for name in WEB_ASSETS}
    url = f'http://127.0.0.1:{server.server_port}/#{server.token}'
    write_json(metadata, {'url': url, 'pid': os.getpid(), 'version': version, 'legacyVersion': server.legacy_version})
    print(url, flush=True)
    sys.stdout.close()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
