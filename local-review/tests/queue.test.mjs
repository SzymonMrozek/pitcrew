import test from 'node:test';
import assert from 'node:assert/strict';
import {queueLabel, renderQueue, mountQueue} from '../queue.mjs';

function element(tag) {
  return {tag, children: [], append(...items) {this.children.push(...items);}, replaceChildren(...items) {this.children = items;}};
}

test('queue cards display all states and keep untrusted titles and paths as text', () => {
  globalThis.document = {createElement: element, createDocumentFragment: () => element('fragment')};
  try {
    const root = element('root');
    const entry = {id: 'abc', sessionId: 'other-review', title: '<script>title</script>', branch: 'feature', target: 'main', phase: 'waiting', status: 'pending', position: 2,
      requestedAt: '2026-10-13T10:00:00Z', changedPaths: ['<img src=x>'], snapshotRef: 'refs/local-review/queue/abc', snapshotBase: 'base'};
    renderQueue(root, {pending: [entry], attention: [], recent: []}, 'token');
    const nodes = [], walk = node => {nodes.push(node); node.children.forEach(walk);}; walk(root);
    assert.ok(nodes.some(node => node.textContent === entry.title));
    assert.ok(nodes.some(node => node.textContent === '<img src=x>'));
    assert.ok(nodes.some(node => node.href === '/?merge=abc&review=other-review#token'));
    assert.equal(queueLabel(entry), 'Waiting · #2');
    for (const phase of ['preparing', 'merging', 'merged', 'blocked']) assert.ok(queueLabel({...entry, phase}));
    assert.ok(nodes.some(node => node.textContent === 'No recorded merges yet.'));
  } finally {delete globalThis.document;}
});

test('queue polling reads only queue status, preserves unchanged cards and pauses when hidden', async () => {
  const originalFetch = globalThis.fetch, originalInterval = globalThis.setInterval;
  let poll, calls = 0, renders = 0, error;
  const root = element('root'); root.hasAttribute = () => false; root.closest = () => ({open: true});
  root.replaceChildren = () => renders++;
  globalThis.document = {visibilityState: 'visible', createElement: element, createDocumentFragment: () => element('fragment')};
  globalThis.setInterval = fn => {poll = fn;};
  globalThis.fetch = async (url, options) => {
    calls++; assert.equal(url, '/api/queue'); assert.equal(options.headers['X-Review-Token'], 'secret');
    return {ok: true, json: async () => ({pending: [], attention: [], recent: []})};
  };
  try {
    const refresh = mountQueue(root, 'secret', value => {error = value;});
    await refresh(); await refresh();
    assert.equal(calls, 2); assert.equal(renders, 1); assert.equal(error, null);
    globalThis.document.visibilityState = 'hidden'; poll(); assert.equal(calls, 2);
    globalThis.fetch = async () => ({ok: false, json: async () => ({error: 'Token rejected'})});
    await refresh(); assert.equal(error.message, 'Token rejected'); assert.equal(renders, 1);
  } finally {
    globalThis.fetch = originalFetch; globalThis.setInterval = originalInterval; delete globalThis.document;
  }
});
