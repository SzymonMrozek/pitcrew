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
import time
import uuid

import threading

from server import (clean_env, early_prompt, env_prefix, load_config, next_while_merging, process_alive, queue_slot,
                    read_json, update_queue_owner, validate_batch, write_json)

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
    early = []

    def deliver_early():
        # Preparing the next approval overlaps the current one's validation; execution still waits for the turn.
        if early or not (prompt := early_prompt(request)) or not next_while_merging(path.parent, request['id']):
            return
        early.append(threading.Thread(target=deliver_reserved, args=(path,), kwargs={'prompt': prompt}, daemon=True))
        early[0].start()

    conversation = request.get('agent') if request.get('deliveryMode') == 'conversation' else None
    try:
        with queue_slot(path.parent, request['id'], wait=True, conversation=conversation,
                        waiting=deliver_early if conversation else None):
            run_batch(path, request)
            if early:
                early[0].join()
                hold_until_finished(path)
                return
            deliver_reserved(path)
    except ValueError:
        return  # A withdrawn approval leaves the queue without launching an agent.


def run_batch(path, request):
    """Validate this approval together with those waiting behind it before its agent starts, if the repository batches."""
    try:
        config = load_config(request['mergeRoot'], strict=False)
    except (OSError, ValueError):
        return
    if config['merge']['batch']['max'] < 2:
        return
    update_queue_owner(path.parent, request['id'], batching=True)
    try:
        validate_batch(path.parent, request['mergeRoot'], config, request['id'])
    except Exception as error:
        print(f'Merge batch validation failed to run: {error}', file=sys.stderr, flush=True)
    finally:
        update_queue_owner(path.parent, request['id'], batching=False)


def hold_until_finished(path):
    while (current := read_json(path, None)) and (current['status'] in ('pending', 'working') or process_alive(current.get('mergePid'))):
        time.sleep(.5)


def deliver_reserved(path, prompt=None):
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
        if request.get('deliveryMode') == 'conversation':
            if prompt:
                update(deliveredEarly=True)
            deliver_merge_conversation(path, {**request, 'prompt': prompt or request['prompt']}, provider, label, cli, update)
            return
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


def require_codex_queue(cli):
    try:
        result = subprocess.run([cli, 'queue', '--help'], capture_output=True, text=True, timeout=10, env=clean_env())
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError(f'Cannot check Codex queue support in {cli}: {error}. The saved request can be retried.') from error
    # Older CLIs accept "queue" as a prompt and print global help with exit status zero.
    if result.returncode or not all(flag in result.stdout for flag in ('--thread', '--message')):
        raise ValueError(f'The saved Codex executable {cli} does not support codex queue --thread --message. '
                         'Run the review launcher from the original Codex chat using a queue-capable CLI '
                         '(or set CODEX_CLI_PATH explicitly), then resume the same saved approval. '
                         'Review feedback remains available to retry; no new approval is needed.')


def conversation_command(provider, cli, session, prompt):
    if not session:
        raise ValueError('No originating agent conversation. Start review from its chat first.')
    if provider == 'claude':
        return [cli, '--resume', session, '--print', '--output-format', 'stream-json', '--verbose',
                '--permission-mode', 'dontAsk', '--allowedTools', *CLAUDE_TOOLS]
    require_codex_queue(cli)
    return [cli, 'queue', '--thread', session, '--message', prompt]


def deliver_merge_conversation(path, request, provider, label, cli, update):
    """Keep the queue reserved while the originating conversation handles its approval."""
    command = conversation_command(provider, cli, request['agent'].get('sessionId'), request['prompt'])
    if not update(delivery='started', summary=f'Sending the merge request to the original {label} conversation. Follow its reply there.'):
        return
    log_path = path.with_name(request['id'] + '-agent.log')
    output = path.with_name(request['id'] + '-agent-response.txt')
    with log_path.open('w') as log:
        result = subprocess.run(command, cwd=request['repo'], input=request['prompt'] if provider == 'claude' else None,
                                stdout=log, stderr=subprocess.STDOUT, text=True, env=clean_env())
    if result.returncode:
        response = final_response(provider, log_path, output).strip()
        update(status='blocked', delivery='failed', summary=response or f'Could not send the merge request to {label}. Resume the saved request.')
        return
    if provider == 'claude':
        response = final_response(provider, log_path, output).strip()
        # A turn can end while its detached execution still waits for the queue or validates.
        while (current := read_json(path, None)) and process_alive(current.get('mergePid')):
            time.sleep(.5)
        update(status='blocked', delivery='finished', summary=response or 'The agent stopped before merging. Resume the saved request in its conversation.')
        return
    update(delivery='delivered', summary='Merge request queued in the original Codex conversation. Follow its progress and reply there.')
    delivered = time.monotonic()
    timeout = request.get('pickupTimeout') or 0
    # Queueing confirms delivery, not completion. The original chat executes the saved request.
    while (current := read_json(path, None)) and current['status'] in ('pending', 'working'):
        if timeout and time.monotonic() - delivered > timeout and not current.get('pickedUpAt') and not current.get('mergePid'):
            minutes = round(timeout / 60)
            update(status='blocked', summary=f'The Codex conversation did not inspect this approval within {minutes} min, so the queue moved on. '
                   'Resume the same request from that conversation with --resume-merge-request; it keeps its queue position.')
            return
        time.sleep(.5)


def deliver_review(path):
    """Send feedback to the conversation that wrote the change."""
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
        command = conversation_command(provider, cli, handoff['agent'].get('sessionId'), handoff['prompt'])
        with log_path.open('w') as log:
            result = subprocess.run(command, cwd=handoff['repo'], input=handoff['prompt'] if provider == 'claude' else None,
                                    stdout=log, stderr=subprocess.STDOUT, text=True, env=clean_env())
        if provider == 'codex' and result.returncode == 0:
            update(status='delivered', finishedAt=datetime.now(timezone.utc).isoformat(),
                   summary='Review queued in the original Codex conversation. Follow its reply there, then refresh to review the changes.')
            return
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
