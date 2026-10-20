import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

test('comment keyboard submission validates through the form and ignores plain Enter and duplicate saves', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const handler = source.slice(source.indexOf("$('#comment-form').onkeydown"), source.indexOf("$('#comment-form').onsubmit"));
  let submitted = 0, prevented = 0;
  const submit = {disabled: false}, form = {querySelector: () => submit, requestSubmit: () => submitted++};
  vm.runInNewContext(handler, {$: () => form});
  const event = {key: 'Enter', currentTarget: form, preventDefault: () => prevented++};
  form.onkeydown(event); assert.equal(submitted, 0);
  form.onkeydown({...event, metaKey: true});
  form.onkeydown({...event, ctrlKey: true}); assert.equal(submitted, 2);
  submit.disabled = true;
  form.onkeydown({...event, metaKey: true}); assert.equal(submitted, 2);
  assert.equal(prevented, 3);
  submit.disabled = false;
  form.onkeydown({...event, metaKey: true, isComposing: true}); assert.equal(submitted, 2);
});

test('updating comments keeps the visible line anchored without rebuilding the feed', async () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const update = source.slice(source.indexOf('async function updateFileComments('), source.indexOf('function commentNode('));
  const content = {scrollTop: 700, getBoundingClientRect: () => ({top: 100})};
  let rerendered = false, selected;
  const line = {dataset: {side: 'new', line: '55'}, getBoundingClientRect: () => ({top: 200, bottom: 220})};
  const body = {ready: true, isConnected: true, querySelectorAll: () => [line], rerender: async () => {rerendered = true;}, querySelector: selector => {selected = selector; return {getBoundingClientRect: () => ({top: 350})};}};
  const card = {dataset: {file: 'file'}, querySelector: () => body};
  const context = vm.createContext({updateChrome() {}, tab: 'all', document: {querySelectorAll: () => [card]}, $: () => content, scrollTarget: 'file'});
  vm.runInContext(update, context); await context.updateFileComments('file');
  assert.equal(rerendered, true);
  assert.equal(selected, '.line-number[data-side="new"][data-line="55"]');
  assert.equal(content.scrollTop, 850);
  assert.equal(context.scrollTarget, null);
});

test('saving a comment submits once and keeps failures editable', async () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const handler = source.slice(source.indexOf("$('#comment-form').onsubmit"), source.indexOf('function feedbackDate('));
  const submit = {disabled: false}, form = {querySelector: () => submit, elements: {text: {value: 'Feedback'}}};
  let pending, resolve, reject, closed = false, updated, calls = 0;
  const context = vm.createContext({$: selector => selector === '#comment-form' ? form : {close() {closed = true;}}, commentTarget: {file: 'file', side: 'file'},
    api: () => {calls++; return new Promise((yes, no) => {resolve = yes; reject = no;});}, run: action => {pending = action();}, updateFileComments: async file => {updated = file;},
  });
  vm.runInContext(handler, context);
  const event = {preventDefault() {}, target: form};
  form.onsubmit(event); form.onsubmit(event);
  assert.equal(calls, 1); assert.equal(submit.disabled, true);
  resolve({}); await pending;
  assert.equal(closed, true); assert.equal(updated, 'file'); assert.equal(submit.disabled, false);
  closed = false; form.onsubmit(event); reject(new Error('Network error'));
  await assert.rejects(pending, /Network error/);
  assert.equal(closed, false); assert.equal(submit.disabled, false);
});

test('a late response cannot overwrite a more recently selected iteration', async () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const load = source.slice(source.indexOf('async function load('), source.indexOf('function renderMergeRequest('));
  const pending = [], displayed = [];
  const context = vm.createContext({
    loadVersion: 0, renderVersion: 0, tab: 'comments', definitionsRequested: true,
    $: () => ({}),
    api: () => new Promise(resolve => pending.push(resolve)),
    updateChrome: () => displayed.push(context.state.scope), renderComments: () => {},
  });
  vm.runInContext(load, context);
  const first = context.load(), second = context.load();
  pending[1]({scope: 'iteration-2', settings: {diffMode: 'unified'}, job: {status: 'idle'}});
  await second;
  pending[0]({scope: 'iteration-1', settings: {diffMode: 'split'}, job: {status: 'idle'}});
  await first;
  assert.deepEqual(displayed, ['iteration-2']);
  assert.equal(context.state.scope, 'iteration-2');
});

test('range comments normalize reverse selection and keep file comments accessible', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const open = source.slice(source.indexOf('function openComment('), source.indexOf("document.addEventListener('pointerup'"));
  const elements = {startLine: {}, endLine: {}, text: {focus() {}}};
  const nodes = {'#comment-form': {elements, reset() {}}, '#comment-range': {}, '#comment-location': {}, '#comment-dialog': {showModal() {}}};
  const context = vm.createContext({$: selector => nodes[selector]});
  vm.runInContext(open, context);
  context.openComment({id: 'code', path: 'code.swift', fingerprint: 'current'}, 'old', 8, 3);
  assert.equal(context.commentTarget.line, 3);
  assert.equal(context.commentTarget.endLine, 8);
  assert.equal(elements.startLine.value, 3);
  assert.equal(elements.endLine.value, 8);
  assert.equal(nodes['#comment-range'].hidden, false);
  assert.equal(elements.startLine.disabled, false);
  context.openComment({id: 'image', path: 'image.png'}, 'file', 0);
  assert.equal(nodes['#comment-range'].hidden, true);
  assert.equal(elements.startLine.disabled, true);
  assert.equal(elements.endLine.disabled, true);
});


test('live merge output follows the tail without pulling readers away from older output', async () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const update = source.slice(source.indexOf('async function updateMergeProgress('), source.indexOf("$('#merge-log').onscroll"));
  const output = {scrollHeight: 1000, clientHeight: 200, scrollTop: 800};
  const nodes = {'#merge-progress': {}, '#merge-log': output, '#merge-log-note': {}, '#merge-worker-chat': {}, '#merge-claude-chat': {}, '#merge-claude-resume': {dataset: {}}};
  let progress = {id: 'request', log: '<script>literal text</script>', running: true, workerThreadId: 'worker-id'};
  const context = vm.createContext({state: {mergeRequest: {id: 'request'}}, claudeConversationOpening: false, mergeLogLoading: false, mergeLogId: 'request', $: selector => nodes[selector], api: async () => progress});
  vm.runInContext(update, context);
  await context.updateMergeProgress();
  assert.equal(output.textContent, progress.log);
  assert.equal(output.scrollTop, 1000);
  assert.equal(nodes['#merge-worker-chat'].href, 'codex://threads/worker-id');
  output.scrollTop = 100;
  progress = {...progress, log: 'Next command completed', workerThreadId: null};
  await context.updateMergeProgress();
  assert.equal(output.scrollTop, 100);
  assert.equal(nodes['#merge-worker-chat'].hidden, true);
  progress = {...progress, provider: 'claude', workerSessionId: 'claude-session', resumeCommand: 'claude --resume claude-session', running: true};
  await context.updateMergeProgress();
  assert.equal(nodes['#merge-claude-chat'].hidden, false);
  assert.equal(nodes['#merge-claude-chat'].disabled, true);
  assert.equal(nodes['#merge-claude-resume'].disabled, true);
  progress = {...progress, running: false};
  await context.updateMergeProgress();
  assert.equal(nodes['#merge-claude-chat'].disabled, false);
  assert.equal(nodes['#merge-claude-resume'].dataset.command, 'claude --resume claude-session');
  progress = {...progress, truncated: true, log: 'Rolling tail'};
  await context.updateMergeProgress();
  assert.equal(output.textContent, 'Next command completed', 'A rolling tail must not replace text being read');
  progress = {...progress, id: 'stale-request', log: 'Wrong request'};
  await context.updateMergeProgress();
  assert.equal(output.textContent, 'Next command completed');
  context.state.mergeRequest.deliveryMode = 'conversation';
  context.api = () => {throw new Error('Conversation merges must not request worker output');};
  await context.updateMergeProgress();
  assert.equal(nodes['#merge-progress'].hidden, true);
  assert.equal(context.mergeLogRunning, false);
});


test('scroll selection follows the first card still under the sticky header', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const sync = source.slice(source.indexOf('function syncSelection('), source.indexOf("for (const event of ['wheel'"));
  let selected, scrolled = false;
  const cards = [{dataset: {file: 'above'}, getBoundingClientRect: () => ({bottom: 120})}, {dataset: {file: 'current'}, getBoundingClientRect: () => ({bottom: 700})}, {dataset: {file: 'last'}, getBoundingClientRect: () => ({bottom: 900})}];
  const main = {getBoundingClientRect: () => ({top: 150}), scrollHeight: 1000, scrollTop: 0, clientHeight: 500};
  const context = vm.createContext({tab: 'all', active: 'above', document: {querySelectorAll: () => cards},
    $: selector => selector === '#content' ? main : {scrollIntoView: () => {scrolled = true;}},
    updateSelection: id => {selected = id;},
  });
  vm.runInContext(sync, context); context.syncSelection();
  assert.equal(selected, 'current'); assert.equal(scrolled, true);
  main.scrollTop = 500; context.syncSelection(); assert.equal(selected, 'last', 'The bottom of the feed selects its final card');
  selected = null; context.tab = 'comments'; context.syncSelection(); assert.equal(selected, null);
});

test('line range highlighting stays inside the selected file in a continuous feed', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const highlight = source.slice(source.indexOf('function highlightCommentRange('), source.indexOf('function openComment('));
  const highlighted = [];
  const line = (file, side, number) => ({dataset: {side, line: String(number)}, closest: selector => selector === '.review-file' ? {dataset: {file}} : {classList: {toggle: (name, value) => highlighted.push(value)}}});
  const context = vm.createContext({lineSelection: {file: {id: 'chosen'}, side: 'new', start: 4, end: 2}, document: {querySelectorAll: () => [line('chosen', 'new', 3), line('other', 'new', 3), line('chosen', 'old', 3)]}});
  vm.runInContext(highlight, context); context.highlightCommentRange();
  assert.deepEqual(highlighted, [true, false, false]);
});

test('marking a file viewed jumps to the next unreviewed file and wraps to the top', async () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const mark = source.slice(source.indexOf('// The next unreviewed file below'), source.indexOf("$('#iteration').onchange"));
  const files = ['a', 'b', 'c', 'd'].map(id => ({id, fingerprint: id + '1'}));
  const selected = [], notices = [];
  const context = vm.createContext({
    state: {files, session: {viewed: {c: 'c1'}}}, active: 'b', visibleFiles: () => files, updateChrome() {}, notice: message => notices.push(message),
    viewed: file => context.state.session.viewed[file.id] === file.fingerprint,
    api: async (path, body) => ({...context.state, session: {viewed: {...context.state.session.viewed, [body.file]: body.fingerprint}}}),
    $: () => ({checked: false}), selectFile: async id => selected.push(id), load: async () => {},
  });
  vm.runInContext(mark, context);
  await context.markAndNext('b');
  assert.deepEqual(selected, ['d'], 'Skips the already reviewed file below');
  await context.markAndNext('d');
  assert.deepEqual(selected, ['d', 'a'], 'Wraps to the first unreviewed file');
  await context.markAndNext('a');
  assert.deepEqual(selected, ['d', 'a']);
  assert.deepEqual(notices, ['Every shown file is reviewed.']);
});

test('send to agent reflects blockers, unsent comments and the last delivery', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const render = source.slice(source.indexOf('function agentName('), source.indexOf('async function updateMergeProgress('));
  const node = () => ({hidden: false, disabled: false, textContent: '', title: '', children: [], replaceChildren() {this.children = [];}, append(...items) {this.children.push(...items);}});
  const send = node(), box = node(), stored = new Map();
  const context = vm.createContext({
    $: selector => selector === '#send-review' ? send : box, watchedMerge: null,
    el: (tag, className, text) => ({tag, className, textContent: text}), button: text => ({tag: 'button', textContent: text}),
    sessionStorage: {getItem: key => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value)},
    state: {agent: {provider: 'claude'}, handoff: {unsent: 2, blocker: null, last: null}},
  });
  vm.runInContext(render, context);
  context.renderHandoff();
  assert.deepEqual([send.hidden, send.disabled, send.textContent, box.hidden], [false, false, 'Send to agent · 2', true]);
  assert.match(send.title, /2 new unresolved comments to the Claude conversation/);
  context.state.handoff = {unsent: 0, blocker: 'The agent is still handling the previous review.', last: {id: 'h1', status: 'running', comments: ['a', 'b'], note: '', agent: {provider: 'claude'}}};
  context.renderHandoff();
  assert.deepEqual([send.disabled, send.textContent, send.title, box.hidden], [true, 'Agent working…', 'The agent is still handling the previous review.', false]);
  assert.equal(box.children[0].textContent, 'Claude is working on your review');
  context.state.handoff.last.agent.provider = 'codex';
  context.renderHandoff();
  assert.equal(box.children[0].textContent, 'Sending review to Codex');
  assert.equal(send.textContent, 'Sending…');
  context.state.handoff = {unsent: 0, blocker: null, last: {id: 'h1', status: 'finished', comments: ['a'], summary: '[a] Renamed.', agent: {provider: 'codex'}}};
  context.renderHandoff();
  assert.deepEqual(box.children.map(child => child.textContent), ['Codex finished your review', '[a] Renamed.', 'Refresh', 'Dismiss']);
  context.state.handoff.last.status = 'delivered';
  context.state.handoff.last.summary = 'Review queued in the original conversation.';
  context.renderHandoff();
  assert.deepEqual(box.children.map(child => child.textContent), ['Review sent to Codex', 'Review queued in the original conversation.', 'Refresh', 'Dismiss']);
  stored.set('review-handoff-dismissed', 'h1');
  context.renderHandoff();
  assert.equal(box.hidden, true);
  context.state.handoff = null;
  context.renderHandoff();
  assert.deepEqual([send.hidden, send.disabled], [true, true], 'Saved merge views cannot send');
});

test('filtered files explain matching defaults and custom exclusions', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const filter = source.slice(source.indexOf('function filterReason('), source.indexOf('function viewed('));
  const context = vm.createContext({state: {settings: {hideTests: true, hideLocalization: true, hideGenerated: true, exclude: ['generated']}}, globMatch: (pattern, path) => path.startsWith(pattern)});
  vm.runInContext(filter, context);
  assert.equal(context.filterReason({kind: 'test', path: 'Test.swift'}), 'Unit tests');
  assert.equal(context.filterReason({kind: 'snapshot', path: 'Tests/image.png'}), '');
  assert.equal(context.filterReason({path: 'generated/Code.swift'}), 'Excluded by generated');
  assert.equal(context.filterReason({kind: 'generated', path: 'Sources/user.pb.swift'}), 'Generated code');
});


test('offscreen comparisons preserve height and invalidate late responses across remounts', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const feed = source.slice(source.indexOf('function renderFeed('), source.indexOf('async function selectFile('));
  let observe; const checks = [];
  const main = {replaceChildren() {}, classList: {toggle() {}}};
  const body = {style: {}, isConnected: true, replaceChildren() {}, closest: () => ({dataset: {file: 'snapshot'}}), getBoundingClientRect: () => ({height: 620})};
  const context = vm.createContext({feedObserver: undefined, renderVersion: 0, tab: 'snapshot', state: {files: [{id: 'snapshot'}]},
    $: selector => selector === '#content' ? main : {checked: true}, el: () => ({}), visibleFiles: () => [],
    run: action => action(), renderFile: (file, node, current) => {checks.push(current);},
    IntersectionObserver: class {constructor(callback) {observe = callback;} disconnect() {}},
  });
  vm.runInContext(feed, context); context.renderFeed();
  observe([{target: body, isIntersecting: true}]); assert.equal(checks[0](), true);
  observe([{target: body, isIntersecting: false}]); assert.equal(body.style.height, '620px'); assert.equal(checks[0](), false);
  observe([{target: body, isIntersecting: true}]); assert.equal(checks[0](), false); assert.equal(checks[1](), true);
  context.renderVersion++; assert.equal(checks[1](), false);
});


test('background ranking reorders the feed without replacing cards or moving the selected file', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const reorder = source.slice(source.indexOf('function reorderFeed('), source.indexOf('function updateSelection('));
  const main = {cards: [], scrollTop: 0, append(...cards) {this.cards = cards;}};
  const cards = ['a', 'b', 'c'].map(id => {const card = {dataset: {file: id}, getBoundingClientRect: () => ({top: main.cards.indexOf(card) * 300 - main.scrollTop})}; return card;});
  main.cards = cards;
  const context = vm.createContext({active: 'b', $: () => main, document: {querySelectorAll: () => main.cards}});
  vm.runInContext(reorder, context); context.reorderFeed([{id: 'c'}, {id: 'a'}, {id: 'b'}]);
  assert.deepEqual(main.cards, [cards[2], cards[0], cards[1]]);
  assert.equal(cards[1].getBoundingClientRect().top, 300);
});


test('merge confirmation keeps the reviewed diff identity across background state updates', async () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const merge = source.slice(source.indexOf('let mergeRevision;'), source.indexOf("document.addEventListener('keydown', event =>"));
  const form = {elements: {title: {}, description: {}}, querySelector: () => ({disabled: false})};
  const nodes = {'#approve': {}, '#merge-description': {}, '#merge-summary': {}, '#merge-agent-note': {}, '#merge-form': form, '#merge-dialog': {showModal() {}, close() {}}};
  let submitted, pending;
  const state = {branch: 'feature', target: 'main', agent: {provider: 'codex'}, merge: {revision: 'reviewed-diff', fileCount: 3, draft: {title: '', description: ''}}};
  const demoMissing = demos => Boolean(demos?.uiPaths.length && !demos.total && !demos.skipped);
  const uiChanges = demos => `${demos.uiPaths.length} changed files affect`;
  const context = vm.createContext({state, agentName: () => "Codex", $: selector => nodes[selector], updateChrome() {}, notice() {}, demoMissing, uiChanges,
    run: action => {pending = action();}, api: async (path, body) => {submitted = body; return state;},
  });
  vm.runInContext(merge, context); nodes['#approve'].onclick();
  state.merge.revision = 'unreviewed-diff';
  nodes['#merge-form'].onsubmit({preventDefault() {}, target: form}); await pending;
  assert.equal(submitted.revision, 'reviewed-diff');
  assert.match(nodes['#merge-summary'].textContent, /first update from the latest main/);
  assert.doesNotMatch(nodes['#merge-summary'].textContent, /demo/);
  assert.match(nodes['#merge-agent-note'].textContent, /conversation that wrote this change, just like review comments/);
  state.demos = {uiPaths: ['App/Screen.swift', 'App/Row.swift'], total: 0, skipped: null};
  nodes['#approve'].onclick();
  assert.match(nodes['#merge-summary'].textContent, /No demo recording is attached, although 2 changed files affect the app UI\.$/);
});


test('scoped requests retain their review identity for diff and timing APIs', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const fn = source.slice(source.indexOf('function scopedPath('), source.indexOf('async function api('));
  const context = vm.createContext({reviewId: 'thread-review', watchedMerge: 'saved-merge', iteration: 'thread'});
  vm.runInContext(fn, context);
  assert.equal(context.scopedPath('file?id=abc'), 'file?id=abc&review=thread-review&merge=saved-merge&iteration=thread');
  assert.equal(context.scopedPath('review-time', null), 'review-time?review=thread-review&merge=saved-merge');
});

test('tool feedback saves without requiring a current diff file or loaded state', async () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const fn = source.slice(source.indexOf("$('#feedback-form').onsubmit"), source.indexOf("$('#feedback-export').onclick"));
  const submit = {disabled: false};
  const form = {elements: {text: {value: 'Feedback about the review tool'}}, reset() {}, querySelector: () => submit};
  const nodes = {'#feedback-form': form, '#feedback-submit': submit};
  let pending, submitted;
  const context = vm.createContext({$: selector => nodes[selector], feedbackTab: 'open',
    run: action => {pending = action();}, api: async (path, body) => {submitted = {path, body};}, loadFeedback: async () => {}, notice() {}});
  vm.runInContext(fn, context);
  form.onsubmit({preventDefault() {}, target: form}); await pending;
  assert.equal(submitted.path, 'feedback');
  assert.equal(submitted.body.text, form.elements.text.value);
  assert.equal('file' in submitted.body, false);
});

test('review time pauses for requested, running, merged and saved merge views', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const fn = source.slice(source.indexOf('function reviewTimePaused('), source.indexOf('function sampleReviewTime('));
  const context = vm.createContext({watchedMerge: null, state: undefined});
  vm.runInContext(fn, context);
  assert.equal(context.reviewTimePaused(), false, 'Timing works before state loads');
  for (const [mergeRequest, job, paused] of [[null, 'idle', false], [{status: 'blocked'}, 'idle', false], [{status: 'cancelled'}, 'idle', false],
    [{status: 'pending'}, 'idle', true], [{status: 'working'}, 'idle', true], [{status: 'merged'}, 'idle', true], [null, 'running', true], [null, 'merged', true], [null, 'failed', false]]) {
    context.state = {mergeRequest, job: {status: job}};
    assert.equal(context.reviewTimePaused(), paused, `${mergeRequest?.status} / ${job}`);
  }
  context.state = {mergeRequest: null, job: {status: 'idle'}};
  context.watchedMerge = 'saved-merge';
  assert.equal(context.reviewTimePaused(), true);
});

test('code search results mark every match without interpreting the line as HTML', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const marked = source.slice(source.indexOf('function markedText('), source.indexOf('async function runCodeSearch('));
  const node = (tag, text = '') => ({tag, text, children: [], append(...items) {this.children.push(...items);}});
  const context = vm.createContext({el: (tag, _className, text) => node(tag, text), document: {createTextNode: text => node('#text', text)}});
  vm.runInContext(marked, context);
  const parts = code => code.children.map(child => [child.tag, child.text]).filter(([, text]) => text);
  assert.deepEqual(parts(context.markedText('<b>Load</b> load', 'load', false)), [['#text', '<b>'], ['mark', 'Load'], ['#text', '</b> '], ['mark', 'load']]);
  assert.deepEqual(parts(context.markedText('Load load', 'load', true)), [['#text', 'Load '], ['mark', 'load']]);
});

test('only Swift method declarations become caller links', () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const mark = source.slice(source.indexOf('// Method declarations offer'), source.indexOf('function closeDefinitionMenu()'));
  const text = value => ({nodeType: 3, textContent: value});
  const token = (type, value, previousSibling) => {const classes = new Set(['tok-' + type]); return {nodeType: 1, textContent: value, previousSibling, classList: {contains: name => classes.has(name), add: name => classes.add(name)}};};
  const declaration = token('function', 'load', text(' ')); declaration.previousSibling.previousSibling = token('keyword', 'func', null);
  const call = token('function', 'load', text(' = ')); call.previousSibling.previousSibling = token('keyword', 'let', null);
  const first = token('function', 'start', null);
  const context = vm.createContext({Node: {TEXT_NODE: 3}});
  vm.runInContext(mark, context);
  context.markCallerLinks({querySelectorAll: () => [declaration, call, first]});
  assert.deepEqual([declaration, call, first].map(node => node.classList.contains('caller-link')), [true, false, false]);
  assert.equal(declaration.title, 'Click to show callers');
});

test('demos tab plays recordings inline, keeps QuickTime as an option and flags UI changes without one', async () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const demos = source.slice(source.indexOf('// Changed UI paths with neither'), source.indexOf('function renderJob('));
  const node = (tag, className = '', text) => ({tag, className, textContent: text, disabled: false, children: [], append(...items) {this.children.push(...items);}, replaceChildren(...items) {this.children = items;}});
  const main = node('main'), requests = [], notices = [];
  const context = vm.createContext({
    $: () => main, el: node, button: (text, action, className) => ({...node('button', className, text), action}), feedObserver: null, renderVersion: 0,
    api: async (path, body) => {requests.push([path, body]); return {opened: body.ids.length};}, notice: text => notices.push(text),
    state: {iterations: [{id: 'one', number: 1}], pendingIteration: {id: 'two'}, demos: {uiPaths: ['App/Screen.swift'], total: 0, skipped: null, recording: null, canOpen: true, items: []}},
  });
  vm.runInContext(demos, context);
  const texts = () => main.children.map(child => child.textContent);
  assert.equal(context.demoMissing(context.state.demos), true);
  context.renderDemos();
  assert.match(texts()[2], /^1 changed file affects the app UI, but no demo is attached/);
  assert.equal(texts().at(-1), 'No demo recordings yet.');
  context.state.demos.skipped = {reason: 'Only renames a type.'};
  assert.equal(context.demoMissing(context.state.demos), false);
  context.renderDemos();
  assert.match(texts()[2], /The agent's reason: Only renames a type\./);
  const demo = (id, iteration, available = true) => ({id, iteration, available, src: `/demo?id=${id}`, title: `Demo ${id}`, durationSeconds: 75.4, bytes: 2_400_000, device: 'App feature', appearance: 'dark', recordedAt: '2026-10-20T10:00:00Z'});
  context.state.demos = {...context.state.demos, total: 3, recording: {title: 'Error state', device: 'App feature'}, items: [demo('a', 'one'), demo('b', 'two'), demo('c', null, false)]};
  context.renderDemos();
  assert.equal(texts()[2], 'Recording “Error state” on App feature…');
  const all = main.children[3].children[0], cards = main.children[4].children;
  assert.equal(all.textContent, 'Open all 3 in QuickTime Player');
  const [player, info, quickTime] = [0, 1, 2].map(index => cards.map(card => card.children[index]));
  assert.deepEqual(player.map(item => [item.tag, item.src]), [['video', '/demo?id=a'], ['video', '/demo?id=b'], ['div', undefined]]);
  assert.equal(player[0].controls && player[0].preload, 'metadata');
  assert.match(player[2].textContent, /missing from the review store/);
  assert.deepEqual(info.map(item => item.children[0].textContent), ['Demo a', 'Demo b', 'Demo c']);
  assert.match(info[0].children[1].textContent, /^1:15 · 2\.4 MB · Iteration 1 · App feature · Dark · /);
  assert.match(info[1].children[1].textContent, /Current interaction/);
  assert.match(info[2].children[1].textContent, /Outside recorded interactions/);
  assert.deepEqual(quickTime.map(item => [item.textContent, item.disabled]), [['Open in QuickTime Player', false], ['Open in QuickTime Player', false], ['Open in QuickTime Player', true]]);
  context.renderDemos();
  assert.equal(main.children[4].children[0].children[0], player[0], 'Re-rendering keeps a playing video element');
  await all.action();
  await quickTime[1].action();
  assert.deepEqual(JSON.parse(JSON.stringify(requests)), [['demos/open', {ids: ['a', 'b']}], ['demos/open', {ids: ['b']}]]);
  assert.deepEqual(notices, ['Opened 2 demos in QuickTime Player.', 'Opened the demo in QuickTime Player.']);
  context.state.demos = {...context.state.demos, canOpen: false, items: [demo('a', 'one')]};
  context.renderDemos();
  const only = main.children.at(-1).children[0];
  assert.equal(only.children[0], player[0]);
  assert.equal(only.children[2].disabled, true);
  assert.equal(only.children[2].title, 'QuickTime Player requires macOS');
  context.state.demos = {...context.state.demos, items: [demo('b', 'two')]};
  context.renderDemos();
  context.state.demos = {...context.state.demos, items: [demo('a', 'one')]};
  context.renderDemos();
  assert.notEqual(main.children.at(-1).children[0].children[0], player[0], 'Players of removed demos are released');
});

test('run dialog lists destinations, starts one and summarizes the result', async () => {
  const source = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
  const runCode = source.slice(source.indexOf('let runDestinations;'), source.indexOf("$('#run').onclick"));
  const node = (tag, className = '', text) => ({tag, className, textContent: text, disabled: false, hidden: false, children: [], append(...items) {this.children.push(...items);}, replaceChildren(...items) {this.children = items;}});
  const nodes = {'#run-destinations': node('div'), '#run-status': node('div'), '#run-summary': node('span'), '#run-cancel': node('button'), '#run-dialog': {open: false}, '#run-log': node('pre')};
  const requests = [];
  const destinations = [{id: 'PHONE', name: 'My iPhone', kind: 'device', detail: 'iOS 27.0'}, {id: 'SIM', name: 'Simulator', kind: '', detail: ''}];
  const context = vm.createContext({
    $: selector => nodes[selector], el: node, button: (text, action, className) => ({...node('button', className, text), action}), run: action => action(), updateChrome() {},
    api: async (path, body) => {requests.push([path, body]); if (path === 'run/destinations') return {destinations}; return {...context.state, run: {available: true, last: {destination: destinations[0], status: 'running'}}};},
    state: {run: {available: true, last: null}},
  });
  vm.runInContext(runCode, context);
  await context.loadRunDestinations();
  const list = () => nodes['#run-destinations'].children;
  assert.deepEqual(list().map(item => [item.children[0].children.map(child => child.textContent), item.children[1]?.textContent, item.disabled]),
                   [[['My iPhone', 'iOS 27.0'], 'device', false], [['Simulator'], undefined, false]]);
  await list()[0].action();
  assert.deepEqual(JSON.parse(JSON.stringify(requests.at(-1))), ['run', {destination: 'PHONE'}]);
  assert.equal(nodes['#run-summary'].textContent, 'Building and launching on My iPhone…');
  assert.equal(nodes['#run-cancel'].hidden, false);
  assert.deepEqual(list().map(item => item.disabled), [true, true], 'One run at a time');
  const last = status => ({destination: destinations[0], status, exitCode: status === 'failed' ? 65 : 0});
  assert.equal(context.runSummary(last('succeeded')), 'Launched on My iPhone.');
  assert.match(context.runSummary(last('failed')), /failed with exit status 65/);
  assert.match(context.runSummary(last('ended')), /result is unknown/);
  context.state.run = {available: true, last: last('succeeded')};
  context.renderRun();
  assert.deepEqual([nodes['#run-status'].className, nodes['#run-cancel'].hidden, list()[0].disabled], ['succeeded', true, false]);
  context.api = async () => ({destinations: []});
  await context.loadRunDestinations();
  assert.match(list()[0].textContent, /No destinations are available/);
  context.api = async () => {throw new Error('Running the app is not configured.');};
  await context.loadRunDestinations();
  assert.equal(list()[0].textContent, 'Running the app is not configured.');
});
