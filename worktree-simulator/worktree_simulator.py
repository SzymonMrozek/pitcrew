#!/usr/bin/env python3
"""Give each git worktree its own iOS Simulator device. Python standard library only.

create  reuses or creates a device named --name and records it in a metadata file
delete  shuts down and deletes the recorded device, then removes the metadata file
show    prints the recorded UDID

The metadata file holds shell-quoted PREFIX_UDID and PREFIX_NAME assignments, so hooks can
source it and tools can read it without running it.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

METADATA = '.worktree-simulator/simulator.env'
PREFIX = 'WORKTREE_SIMULATOR'
UDID = re.compile(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}')


def log(message):
    print(message, file=sys.stderr, flush=True)


def simctl(*args):
    try:
        result = subprocess.run(['xcrun', 'simctl', *args], capture_output=True, text=True, timeout=300)
    except FileNotFoundError:
        raise SystemExit('error: xcrun is unavailable; install Xcode and its command line tools')
    if result.returncode:
        raise SystemExit(f'error: simctl {args[0]} failed: ' + (result.stderr.strip() or result.stdout.strip()))
    return result.stdout


def devices():
    groups = json.loads(simctl('list', 'devices', '--json')).get('devices', {})
    return [device for group in groups.values() for device in group]


def read_metadata(path, prefix):
    try:
        lines = Path(path).read_text().splitlines()
    except FileNotFoundError:
        return {}
    values = {}
    for line in lines:
        key, _, value = line.partition('=')
        words = shlex.split(value) if value else []
        if key.startswith(prefix + '_') and len(words) == 1:
            values[key[len(prefix) + 1:]] = words[0]
    return values


def write_metadata(path, prefix, udid, name):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(f'{prefix}_UDID={shlex.quote(udid)}\n{prefix}_NAME={shlex.quote(name)}\n')
    temp.replace(path)


def choose_runtime(requested):
    runtimes = [r for r in json.loads(simctl('list', 'runtimes', '--json')).get('runtimes', [])
                if r.get('isAvailable', True) and r.get('platform', 'iOS') == 'iOS' and 'iOS' in r.get('identifier', '')]
    if requested:
        runtime = next((r for r in runtimes if r['identifier'] == requested), None)
        if runtime is None:
            raise SystemExit(f'error: simulator runtime {requested} is not installed or unavailable')
        return runtime
    if not runtimes:
        raise SystemExit('error: no available iOS simulator runtime; install one in Xcode > Settings > Components')
    return max(runtimes, key=lambda r: tuple(int(part) for part in re.findall(r'\d+', r.get('version', '0'))))


def choose_device_type(runtime, requested):
    supported = runtime.get('supportedDeviceTypes')
    if supported is None:
        supported = json.loads(simctl('list', 'devicetypes', '--json')).get('devicetypes', [])
    if requested:
        if not any(t.get('identifier') == requested for t in supported):
            raise SystemExit(f'error: device type {requested} is not supported by {runtime["identifier"]}')
        return requested
    # The newest plain numbered model (iPhone 17 rather than 17 Pro, Plus or 16e); simctl's order is not a contract.
    plain = [(int(match[1]), t['identifier']) for t in supported
             if (match := re.fullmatch(r'iPhone (\d+)', t.get('name', '')))]
    if not plain:
        raise SystemExit(f'error: {runtime["identifier"]} supports no numbered iPhone; pass --device-type')
    return max(plain)[1]


def create(args):
    recorded = read_metadata(args.metadata, args.env_prefix)
    available = [d for d in devices() if d.get('isAvailable', True)]
    device = next((d for d in available if d['udid'] == recorded.get('UDID')), None)
    device = device or next((d for d in available if d.get('name') == args.name), None)
    if device:
        udid = device['udid']
        log(f'Using existing simulator {device["name"]} ({udid})')
    else:
        runtime = choose_runtime(args.runtime or os.environ.get(args.env_prefix + '_RUNTIME'))
        device_type = choose_device_type(runtime, args.device_type or os.environ.get(args.env_prefix + '_DEVICE_TYPE'))
        udid = simctl('create', args.name, device_type, runtime['identifier']).strip()
        if not UDID.fullmatch(udid):
            raise SystemExit(f'error: simctl create returned an unexpected identifier: {udid!r}')
        log(f'Created simulator {args.name} ({udid}) with {device_type} on {runtime["identifier"]}')
    write_metadata(args.metadata, args.env_prefix, udid, device['name'] if device else args.name)
    print(udid)


def delete(args):
    udid = read_metadata(args.metadata, args.env_prefix).get('UDID')
    if not udid:
        log(f'No simulator recorded in {args.metadata}; nothing to delete')
        return
    if not UDID.fullmatch(udid):
        raise SystemExit(f'error: {args.metadata} records an invalid UDID: {udid!r}')
    device = next((d for d in devices() if d['udid'] == udid), None)
    if device:
        # A shut down device needs no shutdown; one that is already gone is already clean.
        if device.get('state') != 'Shutdown':
            simctl('shutdown', udid)
        simctl('delete', udid)
        log(f'Deleted simulator {device.get("name", udid)} ({udid})')
    Path(args.metadata).unlink(missing_ok=True)


def show(args):
    udid = read_metadata(args.metadata, args.env_prefix).get('UDID')
    if not udid:
        raise SystemExit(f'error: no simulator recorded in {args.metadata}')
    print(udid)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    for name, handler in (('create', create), ('delete', delete), ('show', show)):
        command = commands.add_parser(name)
        command.set_defaults(handler=handler)
        command.add_argument('--metadata', default=METADATA, help=f'Metadata file, relative to the worktree (default: {METADATA})')
        command.add_argument('--env-prefix', default=PREFIX, help=f'Variable prefix in the metadata file (default: {PREFIX})')
        if name == 'create':
            command.add_argument('--name', required=True, help='Device name; an available device with this name is reused')
            command.add_argument('--runtime', help='Runtime identifier (default: <PREFIX>_RUNTIME, else the newest iOS runtime)')
            command.add_argument('--device-type', help='Device type identifier (default: <PREFIX>_DEVICE_TYPE, else the newest plain iPhone)')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Z][A-Z0-9_]*', args.env_prefix):
        parser.error('--env-prefix must be uppercase letters, digits and underscores')
    args.handler(args)


if __name__ == '__main__':
    main()
