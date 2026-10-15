import test from 'node:test';
import assert from 'node:assert/strict';
import {ReviewTime, formatReviewTime, IDLE_LIMIT_MS} from '../review-time.mjs';

const WALL_START = 1_800_000_000_000;

function setup(send, {input = true} = {}) {
  let clock = 0;
  const requests = [];
  const timer = new ReviewTime(send || (async body => requests.push(body)), () => clock, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', () => WALL_START + clock);
  // Most cases model a person who just interacted; idle cases opt out.
  if (input) timer.input();
  return {timer, requests, advance: ms => {clock += ms;}};
}

test('counts reading only while the tab is visible and the browser has focus', async () => {
  const {timer, requests, advance} = setup();
  advance(5000); timer.update(true, false, 'full');
  advance(5000); timer.update(true, true, 'full');
  advance(2000); timer.update(true, false, 'full'); // Switch to another app; the tab is still visible.
  advance(5000); timer.update(true, false, 'full');
  advance(5000); timer.update(false, true, 'full'); // Another tab or minimized window.
  advance(5000); timer.update(true, true, 'full');
  advance(3000); timer.update(true, true, 'full');
  await timer.flush();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].elapsedMs, 5000);
  await timer.flush();
  assert.equal(requests.length, 1, 'Unchanged counters do not send extra requests');
});

test('scope changes split time, pagehide pauses, and long suspended gaps are excluded', async () => {
  const {timer, requests, advance} = setup();
  timer.update(true, true, 'full');
  advance(1500); timer.update(true, true, 'turn-2');
  advance(2500); timer.update(false, false, 'turn-2');
  advance(60000); timer.update(true, true, 'turn-2');
  advance(60000); timer.update(true, true, 'turn-2');
  timer.input(); // The person returns after the suspended gap.
  advance(1000); timer.update(true, true, 'turn-2');
  await timer.flush();
  assert.deepEqual(requests.map(r => [r.scope, r.elapsedMs]), [['full', 1500], ['turn-2', 3500]]);
});

test('failed checkpoints retry and reordered responses cannot reduce a saved counter', async () => {
  let fail = true;
  const pending = [];
  const {timer, advance} = setup(body => fail ? Promise.reject(new Error('offline')) : new Promise(resolve => pending.push({body, resolve})));
  timer.update(true, true, 'full');
  advance(1000); timer.update(true, true, 'full');
  await timer.flush();
  assert.equal(timer.saved.size, 0);
  fail = false;
  const first = timer.flush();
  advance(1000); timer.update(true, true, 'full');
  const second = timer.flush();
  pending[1].resolve(); await second;
  pending[0].resolve(); await first;
  assert.equal(timer.saved.get('full'), 2000);
});

test('a focused page without real input counts nothing, as when an agent opens it in a background browser', async () => {
  const {timer, requests, advance} = setup(undefined, {input: false});
  timer.update(true, true, 'full');
  for (let i = 0; i < 13 * 60; i++) {advance(1000); timer.update(true, true, 'full');}
  await timer.flush();
  assert.equal(requests.length, 0);
});

test('reading counts for two minutes after the last input, then resumes on the next input', async () => {
  const {timer, requests, advance} = setup();
  timer.update(true, true, 'full');
  for (let i = 0; i < 300; i++) {advance(1000); timer.update(true, true, 'full');}
  timer.input();
  for (let i = 0; i < 5; i++) {advance(1000); timer.update(true, true, 'full');}
  await timer.flush();
  assert.equal(requests[0].elapsedMs, IDLE_LIMIT_MS + 5000);
  assert.deepEqual(requests[0].intervals, [[WALL_START, WALL_START + IDLE_LIMIT_MS], [WALL_START + 300000, WALL_START + 305000]]);
});

test('a merge pause stops counting even with recent input', async () => {
  const {timer, requests, advance} = setup();
  timer.update(true, true, 'full');
  advance(3000); timer.update(true, true, 'full', true);
  for (let i = 0; i < 60; i++) {timer.input(); advance(1000); timer.update(true, true, 'full', true);}
  await timer.flush();
  assert.equal(requests[0].elapsedMs, 3000);
  assert.deepEqual(requests[0].intervals, [[WALL_START, WALL_START + 3000]]);
});

test('formats accumulated duration without dropping hours', () => {
  assert.equal(formatReviewTime(0), '0:00');
  assert.equal(formatReviewTime(65000), '1:05');
  assert.equal(formatReviewTime(3600000), '60:00');
});
