#!/usr/bin/env python3
"""Deliver a saved approval or review to its originating agent; never run Git commands here."""
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

from server import env_prefix, read_json, write_json, process_alive, queue_slot

# Session markers inherited from whichever agent started the review server.
AGENT_MARKERS = ('CODEX_THREAD_ID', 'CODEX_SESSION_ID', 'CODEX_APP_TOOLS_PIPE_PATH', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE',
                 'CLAUDECODE', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_PID')
CLAUDE_TOOLS = ('Read', 'Glob', 'Grep', 'Edit', 'Write', 'Bash')


def agent_cli(origin):
    provider = origin.get('provider')
    if provider not in ('codex', 'claude'):
        raise ValueError('No recognized originating agent. Start review from Codex or Claude.')
    label = 'Claude' if provider == 'claude' else 'Codex'
    cli = origin.get('cli') or (os.environ.get('CODEX_CLI_PATH') if provider == 'codex' else None) or shutil.which(provider)
    if not cli:
        raise ValueError(f'{label} CLI is unavailable. Copy the saved request into your agent chat.')
    return provider, label, cli


def clean_env():
    env = dict(os.environ)
    for name in AGENT_MARKERS:
        env.pop(name, None)
    return env


def final_response(provider, log_path, output):
    """The agent's last message, or the end of its log when it gave none."""
    if provider == 'claude':
        response = ''
        with log_path.open() as log:
            for line in log:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if isinstance(event, dict) and event.get('type') == 'result':
                    response = event.get('result', '')
        response = response or log_path.read_text()[-4000:]
        output.write_text(response)
        return response
    return output.read_text() if output.exists() else log_path.read_text()[-4000:]


def deliver(path):
    path = Path(path)
    with path.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        request = read_json(path, None)
        if not request or request['status'] != 'pending' or process_alive(request.get('workerPid')):
            return
        request.update(workerPid=os.getpid(), delivery='queued', summary='Waiting for its merge queue turn; no preparation or tests have started.')
        write_json(path, request)
    try:
        with queue_slot(path.parent, request['id'], wait=True):
            deliver_reserved(path)
    except ValueError:
        return  # A withdrawn approval leaves the queue without launching an agent.


def deliver_reserved(path):
    path = Path(path)
    request = read_json(path, None)
    if not request:
        return
    request_id = request['id']
    lock_path = path.with_suffix('.lock')

    def update(**fields):
        with lock_path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            current = read_json(path, None)
            if not current or current['id'] != request_id or current['status'] != 'pending':
                return False
            current.update(fields)
            write_json(path, current)
            return True

    output = path.with_name(request_id + '-agent-response.txt')
    log_path = path.with_name(request_id + '-agent.log')
    try:
        origin = request.get('agent') or ({'provider': 'codex'} if request.get('threadId') else {})
        provider, label, cli = agent_cli(origin)
        session_id = str(uuid.uuid4()) if provider == 'claude' else None
        if not update(workerSessionId=session_id, delivery='started', summary=f'Sent to a local {label} agent. It is checking readiness and will handle the merge.'):
            return
        env = clean_env()
        # The state directory is named after the configured review name.
        prefix = env_prefix(path.parent.name)
        env[prefix + '_HANDOFF'] = '1'
        env[prefix + '_QUEUE_PID'] = str(os.getpid())
        # Completing a local merge needs Git metadata, tool caches, simulators and loopback access.
        if provider == 'claude':
            command = [cli, '--session-id', session_id, '--print', '--output-format', 'stream-json', '--verbose', '--permission-mode', 'dontAsk',
                '--add-dir', request['mergeRoot'], '--allowedTools', *CLAUDE_TOOLS]
        else:
            command = [cli, 'exec', '--cd', request['repo'], '--sandbox', 'danger-full-access', '-c', 'approval_policy="never"',
                       '--output-last-message', str(output), '-']
        with log_path.open('w') as log:
            result = subprocess.run(command, cwd=request['repo'], input=request['prompt'],
                                    stdout=log, stderr=subprocess.STDOUT, text=True, env=env)
        response = final_response(provider, log_path, output)
        update(status='blocked', delivery='finished' if result.returncode == 0 else 'failed',
               summary=response.strip() or 'The agent stopped without merging. Copy the request into your agent chat to continue.')
    except Exception as error:
        update(status='blocked', delivery='failed', summary=f'Agent delivery failed: {error}')


def deliver_review(path):
    """Resume the conversation that wrote the change with the reviewer's comments."""
    path = Path(path)
    lock_path = path.with_suffix('.lock')
    handoff = read_json(path, None)
    if not handoff or handoff['status'] != 'running':
        return

    def update(**fields):
        with lock_path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            current = read_json(path, None)
            if current and current['id'] == handoff['id']:
                write_json(path, {**current, **fields})

    output = path.with_name(handoff['id'] + '-review-response.txt')
    log_path = path.with_name(handoff['id'] + '-review.log')
    try:
        provider, label, cli = agent_cli(handoff['agent'])
        session = handoff['agent']['sessionId']
        # The original conversation continues, so it keeps recording its own interactions: no handoff marker.
        if provider == 'claude':
            command = [cli, '--resume', session, '--print', '--output-format', 'stream-json', '--verbose',
                       '--permission-mode', 'dontAsk', '--allowedTools', *CLAUDE_TOOLS]
        else:
            command = [cli, 'exec', 'resume', '-c', 'sandbox_mode="danger-full-access"', '-c', 'approval_policy="never"',
                       '--output-last-message', str(output), session, '-']
        with log_path.open('w') as log:
            result = subprocess.run(command, cwd=handoff['repo'], input=handoff['prompt'],
                                    stdout=log, stderr=subprocess.STDOUT, text=True, env=clean_env())
        response = final_response(provider, log_path, output).strip()
        update(status='finished' if result.returncode == 0 else 'failed', finishedAt=datetime.now(timezone.utc).isoformat(),
               summary=response or f'{label} stopped without replying. Open the conversation to continue.')
    except Exception as error:
        update(status='failed', finishedAt=datetime.now(timezone.utc).isoformat(), summary=f'Sending the review failed: {error}')


if __name__ == '__main__':
    if sys.argv[1] == '--review':
        deliver_review(sys.argv[2])
    else:
        deliver(sys.argv[1])
