"""Run with python3 tests/test_worktree_simulator.py; a fake xcrun stands in for CoreSimulator."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / 'worktree_simulator.py'
FAKE_XCRUN = r'''#!/usr/bin/env python3
import json, pathlib, sys, uuid
state = pathlib.Path(sys.argv[0]).with_name('state.json')
data = json.loads(state.read_text())
data['calls'].append(sys.argv[2:])
args = sys.argv[2:]
if args[:2] == ['list', 'devices']:
    print(json.dumps({'devices': {'iOS': data['devices']}}))
elif args[:2] == ['list', 'runtimes']:
    print(json.dumps({'runtimes': data['runtimes']}))
elif args[0] == 'create':
    udid = str(uuid.UUID(int=len(data['devices']) + 1)).upper()
    data['devices'].append({'name': args[1], 'udid': udid, 'state': 'Shutdown', 'isAvailable': True, 'type': args[2], 'runtime': args[3]})
    print(udid)
elif args[0] == 'shutdown':
    next(d for d in data['devices'] if d['udid'] == args[1])['state'] = 'Shutdown'
elif args[0] == 'delete':
    data['devices'] = [d for d in data['devices'] if d['udid'] != args[1]]
state.write_text(json.dumps(data))
'''


def device_types(*names):
    # simctl lists newest first; the tool must not rely on that order.
    return [{'name': name, 'identifier': 'type.' + name.replace(' ', '-'), 'productFamily': 'iPhone'} for name in names]


class WorktreeSimulatorTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'xcrun').write_text(FAKE_XCRUN)
        (bin_dir / 'xcrun').chmod(0o755)
        self.state = bin_dir / 'state.json'
        self.save({'calls': [], 'devices': [], 'runtimes': [
            {'identifier': 'runtime.iOS-26-0', 'version': '26.0', 'platform': 'iOS', 'isAvailable': True,
             'supportedDeviceTypes': device_types('iPhone 17', 'iPhone 16')},
            {'identifier': 'runtime.iOS-27-0', 'version': '27.0', 'platform': 'iOS', 'isAvailable': True,
             'supportedDeviceTypes': device_types('iPhone 18 Pro', 'iPhone 18', 'iPhone 17e', 'iPhone 9')},
            {'identifier': 'runtime.watchOS-27-0', 'version': '27.0', 'platform': 'watchOS', 'isAvailable': True,
             'supportedDeviceTypes': []},
        ]})
        self.env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}'}
        for name in ('WORKTREE_SIMULATOR_RUNTIME', 'WORKTREE_SIMULATOR_DEVICE_TYPE'):
            self.env.pop(name, None)

    def save(self, data):
        self.state.write_text(json.dumps(data))

    def load(self):
        return json.loads(self.state.read_text())

    def run_tool(self, *args, env=None):
        return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.root, env=env or self.env,
                              capture_output=True, text=True, timeout=20)

    def test_create_picks_newest_runtime_and_numbered_iphone_and_records_metadata(self):
        result = self.run_tool('create', '--name', 'App feature-x')
        self.assertEqual(result.returncode, 0, result.stderr)
        udid = result.stdout.strip()
        device = self.load()['devices'][0]
        self.assertEqual((device['udid'], device['type'], device['runtime']), (udid, 'type.iPhone-18', 'runtime.iOS-27-0'))
        metadata = (self.root / '.worktree-simulator/simulator.env').read_text()
        self.assertEqual(metadata, f"WORKTREE_SIMULATOR_UDID={udid}\nWORKTREE_SIMULATOR_NAME='App feature-x'\n")
        sourced = subprocess.run(['bash', '-c', 'source .worktree-simulator/simulator.env && printf "%s|%s" "$WORKTREE_SIMULATOR_UDID" "$WORKTREE_SIMULATOR_NAME"'],
                                 cwd=self.root, capture_output=True, text=True, check=True).stdout
        self.assertEqual(sourced, f'{udid}|App feature-x')
        self.assertEqual(self.run_tool('show').stdout.strip(), udid)

    def test_create_is_idempotent_by_metadata_and_by_name(self):
        first = self.run_tool('create', '--name', 'App one').stdout.strip()
        self.assertEqual(self.run_tool('create', '--name', 'App one').stdout.strip(), first)
        (self.root / '.worktree-simulator/simulator.env').unlink()
        self.assertEqual(self.run_tool('create', '--name', 'App one').stdout.strip(), first, 'An existing device with the name is reused')
        self.assertEqual(len(self.load()['devices']), 1)

    def test_explicit_runtime_and_device_type_come_from_flags_or_environment_and_must_exist(self):
        result = self.run_tool('create', '--name', 'App pinned', '--runtime', 'runtime.iOS-26-0', '--device-type', 'type.iPhone-16')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.load()['devices'][0]['type'], self.load()['devices'][0]['runtime']), ('type.iPhone-16', 'runtime.iOS-26-0'))
        env = {**self.env, 'APP_SIM_RUNTIME': 'runtime.iOS-26-0'}
        result = self.run_tool('create', '--name', 'App env', '--env-prefix', 'APP_SIM', '--metadata', 'state/sim.env', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.load()['devices'][1]['runtime'], 'runtime.iOS-26-0')
        self.assertIn('APP_SIM_UDID=', (self.root / 'state/sim.env').read_text())
        for flags, message in ((['--runtime', 'runtime.iOS-99-0'], 'not installed'), (['--device-type', 'type.iPhone-9000'], 'not supported')):
            result = self.run_tool('create', '--name', 'App missing', '--metadata', 'missing.env', *flags)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
        self.assertEqual(len(self.load()['devices']), 2, 'Failures must not create a device')

    def test_delete_shuts_down_deletes_and_forgets_only_the_recorded_device(self):
        udid = self.run_tool('create', '--name', 'App gone').stdout.strip()
        other = self.run_tool('create', '--name', 'App other', '--metadata', 'other.env').stdout.strip()
        data = self.load()
        data['devices'][0]['state'] = 'Booted'
        self.save(data)
        result = self.run_tool('delete')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([d['udid'] for d in self.load()['devices']], [other])
        self.assertIn(['shutdown', udid], self.load()['calls'])
        self.assertFalse((self.root / '.worktree-simulator/simulator.env').exists())
        result = self.run_tool('delete')
        self.assertEqual(result.returncode, 0, 'Deleting twice is a no-op')
        self.assertIn('nothing to delete', result.stderr)

    def test_delete_tolerates_a_device_removed_elsewhere_and_rejects_unsafe_metadata(self):
        self.run_tool('create', '--name', 'App removed')
        data = self.load()
        data['devices'] = []
        self.save(data)
        self.assertEqual(self.run_tool('delete').returncode, 0)
        (self.root / '.worktree-simulator').mkdir(exist_ok=True)
        (self.root / '.worktree-simulator/simulator.env').write_text('WORKTREE_SIMULATOR_UDID="$(touch pwned)"\n')
        result = self.run_tool('delete')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'pwned').exists())
        self.assertNotIn(['delete', '$(touch pwned)'], self.load()['calls'])

    def test_missing_xcrun_is_reported(self):
        env = {**self.env, 'PATH': '/nonexistent'}
        result = subprocess.run(['/usr/bin/env', '-i', 'PATH=/nonexistent', sys.executable, str(SCRIPT), 'create', '--name', 'x'],
                                cwd=self.root, capture_output=True, text=True, timeout=20, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('xcrun is unavailable', result.stderr)


if __name__ == '__main__':
    unittest.main()
