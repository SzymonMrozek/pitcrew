import {pixelDiff, splitRows, globMatch} from './diff.mjs';
import {ReviewTime, formatReviewTime} from './review-time.mjs';
import {languageFor, highlightRows, highlightLines} from './highlight.mjs';
import {configureModules, moduleFor, moduleLabel, moduleColors} from './modules.mjs';
import {CONTEXT_STEP, contextGaps, expandGap, expandAll, fullyExpanded, withContext} from './context.mjs';
import {rankDefinitions} from './definitions.mjs';
import {mountQueue} from './queue.mjs';
import {isMarkdown, renderMarkdown} from './markdown.mjs';
import {diffStats, signed} from './stats.mjs';
const $ = selector => document.querySelector(selector);
const token = location.hash.slice(1) || sessionStorage.getItem('review-token');
if (token) sessionStorage.setItem('review-token', token);
const refreshQueue = mountQueue(document.querySelector('#queue-content'), token, error => {if (error) notice(error.message);});
const reviewId = new URLSearchParams(location.search).get('review');
document.querySelector('.brand').href = location.pathname + location.search + '#' + token;
document.querySelector('#queue-page').href = '/queue.html' + (reviewId ? '?review=' + encodeURIComponent(reviewId) : '') + '#' + token;
document.querySelector('#queue').onclick = () => {document.querySelector('#queue-dialog').showModal(); void refreshQueue();};
let iteration = new URLSearchParams(location.search).get('iteration');
const watchedMerge = new URLSearchParams(location.search).get('merge');
let mergeLogLoading = false, mergeLogRunning = false, mergeLogId;
let definitionsRequested = false, state, active, tab = 'all', commentTarget, lineSelection, renderVersion = 0, loadVersion = 0, simulatorOpening = false, devMenuTriggering = false, claudeConversationOpening = false;
const images = new Map();
// Expanded context survives lazy remounting; keyed by scope, file and fingerprint so edits reset it.
const expansions = new Map(), fileLines = new Map(), sources = new Map();
let definitionNames = new Set(), definitionMenu, sourceHistory = [], pendingLine, feedbackTab = 'open';
let feedObserver, scrollFrame, scrollTarget, moduleColorMap = new Map();
const el = (tag, className, text) => {const node = document.createElement(tag); if (className) node.className = className; if (text !== undefined) node.textContent = text; return node;};
const button = (text, action, className) => {const node = el('button', className, text); node.type = 'button'; node.onclick = () => run(action); return node;};
const notice = message => {$('#notice').textContent = message; $('#notice').hidden = !message;};
async function run(action) {try {await action();} catch (error) {notice(error.message);}}
function scopedPath(path, scope = iteration) {if (reviewId) path += (path.includes('?') ? '&' : '?') + 'review=' + encodeURIComponent(reviewId); if (watchedMerge) path += (path.includes('?') ? '&' : '?') + 'merge=' + encodeURIComponent(watchedMerge); return path + (scope ? (path.includes('?') ? '&' : '?') + 'iteration=' + encodeURIComponent(scope) : '');}
async function api(path, body) {
  const response = await fetch('/api/' + scopedPath(path), {headers: {'X-Review-Token': token || '', ...(body === undefined ? {} : {'Content-Type': 'application/json'})}, ...(body === undefined ? {} : {method: 'POST', body: JSON.stringify(body)})});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'Request failed');
  return result;
}
function filterReason(file) {
  const s = state.settings;
  if (s.hideLocalization && file.kind === 'localization') return 'Localization';
  if (s.hideTests && file.kind === 'test') return 'Unit tests';
  if (s.hideViews && file.kind === 'view') return 'Views and navigation';
  if (s.hideManifests && file.kind === 'manifest') return 'Project manifests';
  if (s.hideGenerated && file.kind === 'generated') return 'Generated code';
  const pattern = s.exclude.find(pattern => globMatch(pattern, file.path));
  return pattern ? `Excluded by ${pattern}` : '';
}
function hidden(file) {return Boolean(filterReason(file));}
function viewed(file) {return state.session.viewed[file.id] === file.fingerprint;}
function visibleFiles() {
  const search = $('#search').value.toLowerCase();
  return state.files.filter(file => (tab !== 'snapshot' || file.image) && ($('#show-hidden').checked || !hidden(file)) && (!$('#only-unviewed').checked || !viewed(file)) && file.path.toLowerCase().includes(search));
}
function pageTitle(state) {return `${state.threadTitle || state.branch || 'Detached HEAD'} · ${state.tool?.title || 'Local'} review`;}
function moduleNode(file) {
  const module = moduleFor(file.path);
  if (!module) return null;
  const node = el('span', `module-tag module-color-${moduleColorMap.get(module.name) ?? 0}`, moduleLabel(module));
  node.title = `Module ${module.name}${module.target ? ` (${module.target} target)` : ''}${module.group ? ` · ${module.group}` : ''}`;
  return node;
}
function codeNode(tokens, text, language) {
  const code = el('code');
  if (language) code.dataset.language = language;
  if (!tokens) {code.textContent = text; return code;}
  code.append(...tokens.map(token => token.type ? el('span', 'tok-' + token.type, token.text) : document.createTextNode(token.text)));
  return code;
}
function updateReviewTime() {$('#review-time').textContent = 'Active review ' + formatReviewTime(state?.reviewTime?.totalMs || 0);}
function updateChrome() {
  updateReviewTime();
  document.title = pageTitle(state);
  $('#brand-title').textContent = state.tool?.title || 'Local';
  configureModules(state.tool?.modules);
  moduleColorMap = moduleColors(state.files.map(file => moduleFor(file.path)?.name).filter(Boolean));
  $('#branch').textContent = `${state.branch || 'Detached HEAD'} → ${state.target}`;
  const current = state.iterations.find(i => i.id === iteration), lines = diffStats(state.files);
  $('#revision').textContent = `${state.head.slice(0, 8)} · ${current ? `iteration ${current.number}` : iteration === 'thread' ? 'this thread' : 'full diff'} · ${state.files.length} changed files · ${signed(lines.added)} ${signed(-lines.deleted)}${state.agent ? ` · ${state.agent.provider === 'claude' ? 'Claude' : 'Codex'}` : ''}`;
  const selector = $('#iteration');
  const full = el('option', '', 'Full diff'); full.value = '';
  const thread = el('option', '', 'This thread'); thread.value = 'thread'; thread.disabled = !state.threadScopeAvailable;
  selector.replaceChildren(full, thread, ...state.iterations.map(i => {const option = el('option', '', `Iteration ${i.number} · ${i.request}`); option.value = i.id; return option;}));
  selector.value = iteration || '';
  const context = $('#iteration-context');
  context.hidden = !current && iteration !== 'thread';
  context.replaceChildren();
  if (current) context.append(el('strong', '', `Iteration ${current.number}`), el('p', '', current.request), el('p', 'muted', current.summary));
  if (iteration === 'thread') context.append(el('strong', '', 'This thread'), el('p', 'muted', 'Changes from recorded interactions in this chat. Imported changes remain visible in Full diff. Approval always covers the full diff.'));
  $('#progress').textContent = `${state.files.filter(viewed).length} / ${state.files.length} reviewed`;
  $('#snapshot-count').textContent = state.files.filter(f => f.image).length;
  $('#demo-count').textContent = state.demos.items.length;
  $('[data-tab="demos"]').classList.toggle('attention', demoMissing(state.demos));
  $('#comment-count').textContent = state.session.comments.filter(c => !c.resolved).length;
  const ranked = state.files.filter(f => f.scorer === 'Jev').length;
  $('#ranking').textContent = state.ranking?.status === 'running' ? `Jev evaluating · ${ranked}/${state.files.length}` : `Jev · ${ranked}/${state.files.length} scored`;
  $('#rank').disabled = !state.jevAvailable || state.ranking?.status === 'running';
  $('#rank').title = state.jevAvailable ? 'Evaluate uncached changes with Jev' : 'Set JEV_API_KEY in the review server environment to evaluate with Jev';
  const requested = state.mergeRequest && ['pending', 'working'].includes(state.mergeRequest.status);
  $('#approve').textContent = requested ? 'Merge requested' : 'Approve & merge';
  $('#approve').disabled = requested || !state.canMerge || Boolean(state.handoff?.blocker) || state.job.status === 'running' || state.job.status === 'merged';
  $('#approve').title = state.handoff?.blocker || 'Send the full branch approval to the conversation that wrote this change';
  renderMergeRequest();
  renderHandoff();
  run(updateMergeProgress);
  $('#simulator').disabled = simulatorOpening || !state.simulator || state.job.status === 'running' || state.job.status === 'merged';
  $('#simulator').title = state.simulator ? `Open ${state.simulator.name}` : 'No dedicated simulator is assigned to this worktree';
  $('#dev-menu').disabled = devMenuTriggering || !state.simulator || state.job.status === 'running' || state.job.status === 'merged';
  $('#dev-menu').title = state.simulator ? `Open ${state.simulator.name} and send a shake to show its app's Dev Menu` : 'No dedicated simulator is assigned to this worktree';
  $('#run').hidden = !state.run;
  $('#run').disabled = !state.run?.available || state.job.status === 'running' || state.job.status === 'merged';
  $('#run').textContent = state.run?.last?.status === 'running' ? 'Running…' : 'Run…';
  $('#run').title = state.run?.available ? "Build and launch this worktree's app on a device or simulator" : 'The worktree for this review is gone or belongs to another branch';
  $('#refresh').disabled = state.job.status === 'running' || state.job.status === 'merged';
  if (state.ranking?.status === 'done' && state.ranking.fallbacks) $('#ranking').textContent += ` · ${state.ranking.fallbacks} fallback`;
  const files = visibleFiles();
  $('#file-count').textContent = `${files.length} shown · ${state.files.filter(hidden).length} filtered`;
  $('#files').replaceChildren(...files.map(file => {
    const node = button('', () => selectFile(file.id), 'file-button' + (file.id === active ? ' active' : '') + (viewed(file) ? ' reviewed' : ''));
    const name = el('span', 'file-name');
    name.append(el('strong', '', file.path.split('/').pop()), el('small', '', file.path.split('/').slice(0, -1).join('/')));
    const module = moduleNode(file); if (module) name.append(module);
    node.append(el('span', 'file-status', viewed(file) ? '✓' : file.status), name, el('span', 'score' + (file.score >= 75 ? ' high' : ''), file.score));
    node.dataset.file = file.id;
    if (file.id === active) node.setAttribute('aria-current', 'true');
    node.title = `${file.path}\nImportance ${file.score}/100 · ${file.scorer}${file.priority ? ` · ${file.priority}` : ''}`;
    return node;
  }));
  reorderFeed(files);
  const excluded = state.files.filter(hidden);
  $('#filtered-summary').textContent = `Filtered out · ${excluded.length}`;
  $('#filtered-list').replaceChildren(...excluded.map(file => {
    const node = button('', async () => {$('#show-hidden').checked = true; $('#search').value = ''; $('#only-unviewed').checked = false; if (['comments', 'stats', 'demos'].includes(tab) || tab === 'snapshot' && !file.image) tab = 'all'; active = file.id; await load();}, 'file-button');
    const name = el('span', 'file-name'); name.append(el('strong', '', file.path), el('small', '', filterReason(file))); node.append(name); return node;
  }));
  $('#filtered-files').hidden = !excluded.length;
  $('#mode').hidden = ['snapshot', 'comments', 'stats', 'demos'].includes(tab);
  for (const card of document.querySelectorAll('.review-file')) {
    const file = state.files.find(f => f.id === card.dataset.file);
    if (file) card.querySelector('.viewed-check').checked = viewed(file);
    const metadata = card.querySelector('.metadata');
    if (metadata && file) metadata.replaceWith(metadataNode(file));
  }
  document.querySelectorAll('[data-tab]').forEach(node => node.classList.toggle('selected', node.dataset.tab === tab));
}
async function load(refresh = false) {
  const version = ++loadVersion; ++renderVersion;
  const nextState = await api(refresh ? 'refresh' : 'state', refresh ? {} : undefined);
  if (version !== loadVersion) return;
  state = nextState;
  $('#mode').value = state.settings.diffMode;
  if (refresh) {fileLines.clear(); sources.clear();}
  if (refresh || !definitionsRequested) {definitionsRequested = true; run(loadDefinitions);}
  if (refresh) {notice(''); for (const promise of images.values()) promise.then(data => {for (const item of [data.old, data.new]) if (item?.url) URL.revokeObjectURL(item.url);}).catch(() => {}); images.clear();}
  updateChrome();
  if (state.job.status === 'running' || state.job.status === 'merged' || state.job.status === 'failed') {renderJob(); return;}
  if (tab === 'comments') {renderComments(); return;}
  if (tab === 'stats') {renderStats(); return;}
  if (tab === 'demos') {renderDemos(); return;}
  feedObserver?.disconnect();
  if (!visibleFiles().some(f => f.id === active)) active = visibleFiles()[0]?.id;
  if (active) {renderFeed(); await selectFile(active);} else $('#content').replaceChildren(el('div', 'empty', state.files.length ? 'No files match these filters. Enable “Show filtered files” to see all changes.' : 'No changes to review.'));
  if (version === loadVersion) prefetchImages();
}
function renderMergeRequest() {
  const box = $('#merge-request-status'), request = state.mergeRequest;
  box.hidden = !request; box.replaceChildren();
  if (!request) return;
  box.append(el('strong', '', request.status === 'merged' ? 'Merged' : (request.status === 'working' || request.status === 'pending' && request.delivery === 'started') ? 'Agent is handling the merge' : request.status === 'blocked' ? 'Merge needs attention' : request.status === 'cancelled' ? 'Approval withdrawn' : 'Merge requested'));
  box.append(el('span', '', request.status === 'merged' ? `${request.branch} merged into ${request.target}. Follow the result in the agent conversation.` : request.summary));
  if (!watchedMerge && ['pending', 'blocked'].includes(request.status)) {
    if (request.threadId && (!request.agent || request.agent.provider === 'codex')) {const link = el('a', '', 'Open agent chat'); link.href = 'codex://threads/' + encodeURIComponent(request.threadId); box.append(link);}
    box.append(button('Copy request', async () => {await navigator.clipboard.writeText(request.prompt); notice('Copied request. Paste it in the agent chat.');}));
    if (request.status === 'pending') box.append(button('Withdraw approval', async () => {state = await api('merge/cancel', {id: request.id}); updateChrome();}));
    const details = el('details'), prompt = el('textarea'); prompt.readOnly = true; prompt.value = request.prompt; prompt.rows = 4; prompt.setAttribute('aria-label', 'Request for agent'); details.append(el('summary', '', 'Request for agent'), prompt); box.append(details);
  }
}
function agentName(agent) {return agent?.provider === 'claude' ? 'Claude' : 'Codex';}
function renderHandoff() {
  const handoff = state.handoff, last = handoff?.last, send = $('#send-review'), box = $('#review-handoff-status');
  send.hidden = !handoff;
  send.disabled = !handoff || Boolean(handoff.blocker) || Boolean(watchedMerge);
  send.textContent = last?.status === 'running' ? (last.agent?.provider === 'codex' ? 'Sending…' : 'Agent working…') : `Send to agent${handoff?.unsent ? ` · ${handoff.unsent}` : ''}`;
  send.title = handoff?.blocker || `Send ${handoff?.unsent || 'no'} new unresolved comment${handoff?.unsent === 1 ? '' : 's'} to the ${agentName(state.agent)} conversation that wrote this change`;
  let dismissed = null;
  try {dismissed = sessionStorage.getItem('review-handoff-dismissed');} catch {}
  box.hidden = !last || dismissed === last.id;
  box.replaceChildren();
  if (box.hidden) return;
  const name = agentName(last.agent), count = `${last.comments.length} comment${last.comments.length === 1 ? '' : 's'}`;
  box.append(el('strong', '', last.status === 'running' ? (last.agent?.provider === 'codex' ? `Sending review to ${name}` : `${name} is working on your review`) : last.status === 'delivered' ? `Review sent to ${name}` : last.status === 'finished' ? `${name} finished your review` : 'Review not delivered'));
  box.append(el('span', '', last.status === 'running' ? `Sending ${count}${last.note ? ' and a note' : ''} to the conversation that wrote this change. Follow its reply there, then refresh to review the changes.` : last.summary));
  if (last.status !== 'running') {
    if (['delivered', 'finished'].includes(last.status)) box.append(button('Refresh', () => load(true)));
    box.append(button('Dismiss', () => {try {sessionStorage.setItem('review-handoff-dismissed', last.id);} catch {} renderHandoff();}));
  }
}
async function updateMergeProgress() {
  const request = state.mergeRequest, panel = $('#merge-progress');
  panel.hidden = !request || request.deliveryMode === 'conversation';
  if (!request || request.deliveryMode === 'conversation') {mergeLogId = null; mergeLogRunning = false; return;}
  if (mergeLogLoading) return;
  mergeLogLoading = true;
  try {
    const progress = await api('merge-progress');
    if (state.mergeRequest?.id !== progress.id) return;
    const output = $('#merge-log');
    const follow = mergeLogId !== progress.id || output.scrollHeight - output.clientHeight - output.scrollTop < 32;
    const scroll = output.scrollTop;
    if (follow || !progress.truncated) output.textContent = progress.log || 'Waiting for agent output…';
    output.scrollTop = follow ? output.scrollHeight : scroll;
    mergeLogId = progress.id; mergeLogRunning = progress.running;
    $('#merge-log-note').textContent = progress.running ? '· live' : '· saved';
    if (progress.truncated) $('#merge-log-note').textContent += ' · latest 64 KiB shown; download for full output';
    const link = $('#merge-worker-chat');
    link.hidden = !progress.workerThreadId;
    if (progress.workerThreadId) link.href = 'codex://threads/' + encodeURIComponent(progress.workerThreadId);
    const claude = progress.provider === 'claude' && progress.workerSessionId;
    $('#merge-claude-chat').hidden = !claude;
    $('#merge-claude-chat').disabled = progress.running || claudeConversationOpening;
    $('#merge-claude-chat').title = progress.running ? 'Follow live output here; open the conversation after the merge finishes' : 'Open the saved conversation in Claude Desktop or Terminal';
    $('#merge-claude-resume').hidden = !claude;
    $('#merge-claude-resume').disabled = progress.running;
    $('#merge-claude-resume').dataset.command = progress.resumeCommand || '';
    $('#merge-claude-resume').title = $('#merge-claude-chat').title;
  } finally {mergeLogLoading = false;}
}
$('#merge-log').onscroll = () => {const output = $('#merge-log'); if (output.scrollHeight - output.clientHeight - output.scrollTop < 32) run(updateMergeProgress);};
$('#merge-claude-chat').onclick = () => run(async () => {
  claudeConversationOpening = true; $('#merge-claude-chat').disabled = true;
  try {const result = await api('merge-conversation', {}); notice(`Opened the merge conversation in ${result.destination}.`);}
  finally {claudeConversationOpening = false; await updateMergeProgress();}
});
$('#merge-claude-resume').onclick = () => run(async () => {
  await navigator.clipboard.writeText($('#merge-claude-resume').dataset.command);
  notice('Copied the command to resume the saved merge conversation.');
});
$('#merge-log-download').onclick = () => run(async () => {
  const requestId = state.mergeRequest.id;
  const response = await fetch('/api/' + scopedPath('merge-log'), {headers: {'X-Review-Token': token || ''}});
  if (!response.ok) throw new Error('Agent log is not available yet');
  const url = URL.createObjectURL(await response.blob()), link = el('a');
  link.href = url; link.download = `merge-${requestId}.log`; link.click();
  URL.revokeObjectURL(url);
});
function metadataNode(file) {
  const metadata = el('div', 'metadata');
  metadata.append(el('span', 'score' + (file.score >= 75 ? ' high' : ''), `${file.score} importance`), el('span', '', file.scorer + (file.scorer === 'Fallback' ? ' · not evaluated' : '')));
  if (file.priority) metadata.append(el('span', '', `${file.priority} · prioritized`));
  if (!file.binary) metadata.append(el('span', 'added', `+${file.added}`), el('span', 'removed', `−${file.deleted}`));
  if (file.signals) metadata.append(el('span', '', `Business ${file.signals.business} · Performance ${file.signals.performance} · UI ${file.signals.ui}`));
  if (file.submoduleDirty) metadata.append(el('span', '', 'Submodule has uncommitted changes; commit inside it before merging.'));
  return metadata;
}
function reorderFeed(files) {
  const cards = [...document.querySelectorAll('.review-file')];
  if (cards.length !== files.length || !cards.length || !cards.some((card, index) => card.dataset.file !== files[index].id)) return;
  const ordered = files.map(file => cards.find(card => card.dataset.file === file.id));
  if (ordered.some(card => !card)) return;
  const main = $('#content'), selected = cards.find(card => card.dataset.file === active);
  const top = selected?.getBoundingClientRect().top;
  main.append(...ordered);
  if (selected) main.scrollTop += selected.getBoundingClientRect().top - top;
}
function updateSelection(id) {
  active = id;
  for (const node of document.querySelectorAll('#files .file-button')) {
    const selected = node.dataset.file === id;
    node.classList.toggle('active', selected);
    if (selected) node.setAttribute('aria-current', 'true'); else node.removeAttribute('aria-current');
  }
}
function syncSelection() {
  if (tab === 'comments' || tab === 'stats' || tab === 'demos') return;
  const cards = [...document.querySelectorAll('.review-file')];
  const top = $('#content').getBoundingClientRect().top + 64;
  const main = $('#content'), atEnd = main.scrollHeight - main.scrollTop - main.clientHeight < 2;
  const card = atEnd ? cards.at(-1) : cards.find(card => card.getBoundingClientRect().bottom > top);
  if (card && card.dataset.file !== active) {
    updateSelection(card.dataset.file);
    $('#files .active')?.scrollIntoView({block: 'nearest'});
  }
}
for (const event of ['wheel', 'touchstart', 'pointerdown']) $('#content').addEventListener(event, () => {scrollTarget = null;});
$('#content').addEventListener('scroll', () => {
  if (!scrollFrame) scrollFrame = requestAnimationFrame(() => {scrollFrame = null; syncSelection();});
});
function renderFeed() {
  feedObserver?.disconnect(); ++renderVersion; lineSelection = null;
  const version = renderVersion, main = $('#content');
  main.replaceChildren();
  feedObserver = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const body = entry.target, card = body.closest('.review-file');
      if (entry.isIntersecting && !body.mounted) {
        const mount = body.mounted = {};
        body.replaceChildren(el('p', 'muted', 'Loading comparison…'));
        run(() => renderFile(state.files.find(f => f.id === card.dataset.file), body, () => version === renderVersion && body.isConnected && body.mounted === mount));
      } else if (!entry.isIntersecting && body.mounted) {
        // Keep scroll positions stable while releasing offscreen images and diff nodes.
        body.style.height = `${body.getBoundingClientRect().height}px`;
        body.mounted = null; body.ready = false; body.replaceChildren(el('p', 'muted', 'Comparison loads as you scroll.'));
      }
    }
  }, {root: main, rootMargin: '700px 0px'});
  for (const file of visibleFiles()) {
    const card = el('section', 'review-file'); card.dataset.file = file.id; card.dataset.path = file.path;
    const header = el('div', 'file-header'), title = el('div');
    title.append(el('h1', '', file.path.split('/').pop()), el('p', '', file.path));
    const module = moduleNode(file); if (module) title.append(module);
    const actions = el('div', 'file-actions');
    actions.append(button('Comment', () => openComment(file, 'file', 0)));
    if (!file.binary && !file.limited && isMarkdown(file.path)) actions.append(button('Preview Markdown', () => openMarkdown(file)));
    const label = el('label'), check = el('input', 'viewed-check'); check.type = 'checkbox'; check.checked = viewed(file);
    check.onchange = () => run(async () => {
      if (check.checked) {await markAndNext(file.id); return;}
      state = await api('viewed', {file: file.id, fingerprint: file.fingerprint, viewed: false}); updateChrome(); if ($('#only-unviewed').checked) await load();
    });
    label.append(check, document.createTextNode('Viewed')); actions.append(label); header.append(title, actions);
    const body = el('div', 'file-body'); body.style.height = file.image ? '500px' : '300px';
    body.append(el('p', 'muted', 'Comparison loads as you scroll.'));
    card.append(header, body); main.append(card); feedObserver.observe(body);
  }
}
async function selectFile(id) {
  lineSelection = null; scrollTarget = id; updateSelection(id);
  const card = [...document.querySelectorAll('.review-file')].find(card => card.dataset.file === id);
  card?.scrollIntoView({block: 'start'});
  if (card?.querySelector('.file-body').ready) scrollTarget = null;
}
function expansionKey(file) {return `${iteration || 'full'}:${file.id}:${file.fingerprint}`;}
function linesFor(file) {
  const key = expansionKey(file);
  if (!fileLines.has(key)) fileLines.set(key, api('file-lines?id=' + file.id).catch(error => {fileLines.delete(key); throw error;}));
  return fileLines.get(key);
}
let markdownLines;
function updateMarkdown() {
  const side = $('#markdown-side').value;
  $('#markdown-body').innerHTML = renderMarkdown(markdownLines[side].join('\n')) || '<p class="muted">Empty file.</p>';
}
async function openMarkdown(file) {
  const scope = iteration, lines = await linesFor(file);
  if (scope !== iteration) return;
  markdownLines = lines;
  $('#markdown-name').textContent = file.path;
  $('#markdown-side').value = file.status === 'D' ? 'old' : 'new';
  updateMarkdown();
  $('#markdown-dialog').showModal();
  $('#markdown-dialog').scrollTop = 0;
}
$('#markdown-side').onchange = updateMarkdown;
async function expandContext(file, main, gap, direction) {
  const key = expansionKey(file), map = new Map(expansions.get(key) || []);
  if (gap) map.set(gap.key, expandGap(map.get(gap.key), gap, direction));
  // Keep the next change in place when lines are revealed above it.
  const anchorLine = gap && direction === 'after' ? gap.newStart + gap.length : null;
  const anchor = anchorLine && main.querySelector(`.diff-row[data-new="${anchorLine}"]`), top = anchor?.getBoundingClientRect().top;
  expansions.set(key, map);
  await main.rerender();
  const moved = anchorLine && main.querySelector(`.diff-row[data-new="${anchorLine}"]`);
  if (moved && top !== undefined) $('#content').scrollTop += moved.getBoundingClientRect().top - top;
}
async function toggleFullFile(file, main, gaps, full) {
  if (full) expansions.delete(expansionKey(file)); else {await linesFor(file); expansions.set(expansionKey(file), expandAll(gaps));}
  await main.rerender();
}
function gapNode(file, main, part, gap) {
  const row = el('div', 'diff-row gap-row'), cell = el('div', 'code-cell hunk');
  if (gap) {
    const controls = el('span', 'gap-controls'), step = Math.min(CONTEXT_STEP, part.hidden), plural = n => `${n} line${n === 1 ? '' : 's'}`;
    const expand = (label, direction, title) => {const node = button(label, () => expandContext(file, main, gap, direction), 'gap-button'); node.title = title; return node;};
    if (part.hidden > CONTEXT_STEP && !part.first) controls.append(expand(`↓ ${step}`, 'before', `Show ${plural(step)} below the previous change`));
    if (part.hidden > CONTEXT_STEP && !part.last) controls.append(expand(`↑ ${step}`, 'after', `Show ${plural(step)} above the next change`));
    controls.append(expand(`Show ${plural(part.hidden)}`, 'all', 'Show every hidden line in this gap'));
    cell.append(controls, el('span', 'gap-text', part.text));
  } else cell.textContent = part.text;
  row.append(cell);
  return row;
}
async function renderFile(file, main, current) {
  const id = file.id;
  main.rerender = () => renderFile(file, main, current);
  // Text files fetch before clearing so re-rendering after an expansion does not collapse the card.
  const data = file.image ? null : await api('file?id=' + id);
  const lines = data && expansions.has(expansionKey(file)) ? await linesFor(file) : null;
  if (!current()) return;
  main.replaceChildren();
  main.append(metadataNode(file));
  const shown = {old: new Set(), new: new Set()};
  if (file.image) {
    const tools = el('div', 'snapshot-tools');
    tools.append(el('span', '', `Old / new / pixel diff · ${state.settings.imageScale}% · click an image to inspect full size`), button('Viewed → next', () => markAndNext(file.id))); main.append(tools);
    const grid = el('div', 'image-grid');
    const panels = ['Old', 'New', 'Diff'].map(name => {const panel = el('section', 'image-panel'), stage = el('div', 'image-stage', 'Loading…'), info = el('div', 'image-info', ''); panel.append(el('h3', '', name.toUpperCase()), stage, info); grid.append(panel); return {stage, info};});
    main.append(grid);
    const snapshot = await imageData(file);
    if (!current()) return;
    [snapshot.old, snapshot.new, snapshot.diff].forEach((item, index) => {
      const {stage, info} = panels[index]; stage.replaceChildren();
      if (!item || item.error) {stage.textContent = item?.error || (index === 0 ? 'Added image' : index === 1 ? 'Deleted image' : 'No comparison'); return;}
      const node = index === 2 ? item.canvas.cloneNode() : item.image;
      if (index === 2) node.getContext('2d').drawImage(item.canvas, 0, 0); else {node.alt = `${index === 0 ? 'Old' : 'New'} snapshot of ${file.path}`;}
      const width = Math.min(item.width / (window.devicePixelRatio || 1) * state.settings.imageScale / 100, stage.clientWidth - 16, window.innerHeight * 0.65 * item.width / item.height);
      node.style.width = `${width}px`;
      node.onclick = () => {const dialog = el('dialog'); const copy = el('canvas'); copy.width = item.width; copy.height = item.height; copy.getContext('2d').drawImage(index === 2 ? item.canvas : item.image, 0, 0); copy.style.cssText = 'max-width:100%;height:auto'; dialog.style.width = '95vw'; dialog.append(button('Close', () => dialog.close()), copy); document.body.append(dialog); dialog.addEventListener('close', () => dialog.remove()); dialog.showModal();};
      stage.append(node); info.textContent = `${item.width} × ${item.height}` + (index === 2 ? ` · ${snapshot.changed.toLocaleString()} changed pixels (${(100 * snapshot.changed / (item.width * item.height)).toFixed(2)}%)` : '');
    });
  } else {
    if (data.binary || data.limited || !data.rows.length) main.append(el('div', 'empty', data.limited ? 'Large file: text diff omitted. Inspect it in your editor.' : data.binary ? 'Binary change. Inspect the file in your editor.' : 'File metadata or mode change; no text differences.'));
    else {
      const gaps = contextGaps(data.rows, data.oldCount, data.newCount), gapsByKey = new Map(gaps.map(gap => [gap.key, gap]));
      const full = gaps.length > 0 && Boolean(lines) && fullyExpanded(gaps, expansions.get(expansionKey(file)));
      const tools = el('div', 'diff-tools');
      tools.append(el('span', 'muted', 'Drag across line numbers to comment on a range, or click a line and edit the range in the dialog.'));
      if (gaps.length) tools.append(button(full ? 'Collapse context' : 'Show full file', () => toggleFullFile(file, main, gaps, full)));
      main.append(tools);
      const box = el('div', 'diff-box'), displayRows = withContext(data.rows, gaps, lines, expansions.get(expansionKey(file)));
      const firstLine = lines ? (lines.new[0] ?? lines.old[0]) : data.rows.find(row => row.old === 1 || row.new === 1)?.text;
      const language = languageFor(file.path, firstLine);
      const highlighted = highlightRows(displayRows, language), tokens = new Map(displayRows.map((row, index) => [row, highlighted[index]]));
      for (const row of displayRows) {if (row.old != null) shown.old.add(row.old); if (row.new != null) shown.new.add(row.new);}
      const rows = $('#mode').value === 'split' ? splitRows(displayRows) : displayRows.map(row => ({left: row, right: null}));
      rows.forEach(pair => {
        if (pair.left?.type === 'hunk') {box.append(gapNode(file, main, pair.left, gapsByKey.get(pair.left.gap))); return;}
        const unified = $('#mode').value === 'unified', row = el('div', 'diff-row' + (unified ? ' unified' : ''));
        if (pair.left?.old != null) row.dataset.old = pair.left.old;
        const newLine = (pair.right || pair.left)?.new; if (newLine != null && (!unified || pair.left.type !== 'delete')) row.dataset.new = newLine;
        const sides = unified ? [[pair.left, pair.left?.type === 'delete' ? 'old' : 'new']] : [[pair.left, 'old'], [pair.right, 'new']];
        sides.forEach(([part, side]) => {
          const cell = el('div', 'code-cell ' + (part?.type || 'empty-cell') + (part?.expanded ? ' expanded' : ''));
          if (part) {
            const number = part[side], line = button(number ?? '', () => {}, 'line-number');
            line.disabled = !number; line.title = `Comment on ${side} line ${number}; drag to select a range`;
            line.dataset.side = side; line.dataset.line = number ?? '';
            line.onclick = event => {if (event.detail === 0 && number) openComment(file, side, number);};
            line.onpointerdown = event => {if (event.button !== 0 || !number) return; event.preventDefault(); line.focus(); lineSelection = {file, side, start: number, end: number}; highlightCommentRange();};
            line.onpointerenter = event => {if (!lineSelection || lineSelection.file.id !== file.id || !(event.buttons & 1) || lineSelection.side !== side || !number) return; lineSelection.end = number; highlightCommentRange();};
            cell.append(line, codeNode(tokens.get(part)?.[side], part.text, language));
          }
          row.append(cell);
        });
        box.append(row);
        for (const comment of state.session.comments.filter(c => c.file === file.id && c.fingerprint === file.fingerprint && c.side !== 'file' && ((c.side === 'old' && pair.left?.old === (c.endLine ?? c.line)) || (c.side === 'new' && (pair.right || pair.left)?.new === (c.endLine ?? c.line))))) box.append(commentNode(comment));
      }); main.append(box);
      markDefinitionLinks(box); markCallerLinks(box);
    }
  }
  // Comments on collapsed context lines stay visible below the diff until their lines are expanded.
  const comments = state.session.comments.filter(c => c.file === id && (file.image || c.side === 'file' || c.fingerprint !== file.fingerprint || !shown[c.side]?.has(c.endLine ?? c.line)));
  if (comments.length) {main.append(el('h2', 'comments-title', 'File comments')); comments.forEach(c => main.append(commentNode(c)));}
  main.style.height = ''; main.ready = true;
  if (scrollTarget) {
    const card = [...document.querySelectorAll('.review-file')].find(card => card.dataset.file === scrollTarget);
    card?.scrollIntoView({block: 'start'});
    if (scrollTarget === file.id) scrollTarget = null;
  }
  if (pendingLine?.file === file.id) {
    const row = main.querySelector(`.diff-row[data-${pendingLine.side}="${pendingLine.line}"]`);
    pendingLine = null;
    if (row) {row.scrollIntoView({block: 'center'}); flash(row);}
  }
  requestAnimationFrame(syncSelection);
}
async function fetchImage(id, side, scope) {
  const response = await fetch('/api/' + scopedPath(`image?id=${id}&side=${side}`, scope), {headers: {'X-Review-Token': token}});
  if (response.status === 404) return null;
  if (!response.ok) return {error: (await response.json()).error};
  const url = URL.createObjectURL(await response.blob()), image = new Image(); image.src = url;
  try {await image.decode(); return {image, url, width: image.naturalWidth, height: image.naturalHeight};} catch {URL.revokeObjectURL(url); return {error: 'Image could not be decoded'};}
}
function imageData(file, scope = iteration) {
  const key = (scope || 'full') + ':' + file.id + file.fingerprint;
  if (!images.has(key)) images.set(key, (async () => {
    const [old, next] = await Promise.all([fetchImage(file.id, 'old', scope), fetchImage(file.id, 'new', scope)]);
    let diff = null, changed = 0;
    if (old && next && !old.error && !next.error) {
      const width = Math.max(old.width, next.width), height = Math.max(old.height, next.height);
      const pixels = item => {const c = document.createElement('canvas'); c.width = width; c.height = height; const ctx = c.getContext('2d', {willReadFrequently: true}); ctx.drawImage(item.image, 0, 0); return ctx.getImageData(0, 0, width, height).data;};
      const result = pixelDiff(pixels(old), pixels(next)); changed = result.changed;
      const canvas = document.createElement('canvas'); canvas.width = width; canvas.height = height; canvas.getContext('2d').putImageData(new ImageData(result.pixels, width, height), 0, 0); diff = {canvas, width, height};
    }
    return {old, new: next, diff, changed};
  })());
  while (images.size > 5) {
    const discard = [...images.keys()].find(k => k !== key && !k.startsWith((iteration || 'full') + ':' + (active || '')));
    if (!discard) break;
    images.get(discard).then(data => {for (const item of [data.old, data.new]) if (item?.url) URL.revokeObjectURL(item.url);}).catch(() => {});
    images.delete(discard);
  }
  return images.get(key);
}
async function prefetchImages() {
  const snapshots = state.files.filter(f => f.image), position = Math.max(0, snapshots.findIndex(f => f.id === active));
  const files = snapshots.slice(position, position + 3), scope = iteration; let next = 0;
  await Promise.all(Array.from({length: 3}, async () => {while (next < files.length) {const file = files[next++]; try {await imageData(file, scope);} catch {images.delete((scope || 'full') + ':' + file.id + file.fingerprint);}}}));
}
function highlightCommentRange() {
  const low = Math.min(lineSelection.start, lineSelection.end), high = Math.max(lineSelection.start, lineSelection.end);
  document.querySelectorAll('#content .line-number').forEach(line => line.closest('.code-cell').classList.toggle('selected-lines', line.closest('.review-file').dataset.file === lineSelection.file.id && line.dataset.side === lineSelection.side && Number(line.dataset.line) >= low && Number(line.dataset.line) <= high));
}
function openComment(file, side, line, endLine = line) {
  commentTarget = {file: file.id, fingerprint: file.fingerprint, side, line: Math.min(line, endLine), endLine: Math.max(line, endLine)};
  $('#comment-location').textContent = `${file.path}${side !== 'file' ? ` · ${side} lines` : ''}`;
  const form = $('#comment-form'); form.reset();
  $('#comment-range').hidden = side === 'file';
  for (const key of ['startLine', 'endLine']) form.elements[key].disabled = side === 'file';
  form.elements.startLine.value = commentTarget.line; form.elements.endLine.value = commentTarget.endLine;
  $('#comment-dialog').showModal(); form.elements.text.focus();
}
document.addEventListener('pointerup', event => {if (event.button !== 0 || !lineSelection) return; const {file, side, start, end} = lineSelection; lineSelection = null; openComment(file, side, start, end);});
document.addEventListener('pointercancel', () => {lineSelection = null;});
$('#comment-dialog').addEventListener('close', () => {lineSelection = null; document.querySelectorAll('#content .selected-lines').forEach(cell => cell.classList.remove('selected-lines'));});
async function updateFileComments(fileId) {
  updateChrome();
  if (tab === 'comments') {renderComments(); return;}
  const card = [...document.querySelectorAll('.review-file')].find(card => card.dataset.file === fileId);
  const body = card?.querySelector('.file-body');
  if (!body?.ready) return;
  const content = $('#content'), top = content.getBoundingClientRect().top + 64;
  const line = [...body.querySelectorAll('.line-number:not(:disabled)')].find(node => node.getBoundingClientRect().bottom > top);
  const selector = line && `.line-number[data-side="${line.dataset.side}"][data-line="${line.dataset.line}"]`;
  const anchor = line || body, before = anchor.getBoundingClientRect().top;
  // Keep the feed and other comparisons mounted, anchoring the line the reviewer is reading.
  scrollTarget = null;
  await body.rerender();
  if (!body.isConnected || !body.ready) return;
  const moved = selector ? body.querySelector(selector) : body;
  if (moved) content.scrollTop += moved.getBoundingClientRect().top - before;
}
function commentNode(comment) {
  const file = state.files.find(f => f.id === comment.file), stale = !file || file.fingerprint !== comment.fingerprint;
  const node = el('div', 'comment' + (comment.resolved ? ' resolved' : '') + (stale ? ' stale' : ''));
  node.append(button(comment.resolved ? 'Reopen' : 'Resolve', async () => {state = await api('resolve', {id: comment.id, resolved: !comment.resolved}); await updateFileComments(comment.file);}));
  const location = button(`${comment.path}${comment.line ? `:${comment.line}${comment.endLine && comment.endLine !== comment.line ? `–${comment.endLine}` : ''}` : ''}`, async () => {
    await showInDiff(file, stale || comment.side === 'file' ? 0 : comment.line, comment.side);
    if (stale) notice('This comment is outdated; opened the current file. Its original line may have moved.');
  }, 'comment-location');
  location.disabled = !file;
  location.title = !file ? 'This file is no longer in the selected review scope' : stale ? 'Open the current file; the comment refers to an outdated revision' : 'Show this comment’s location in the diff';
  node.append(location);
  node.append(el('small', '', `${comment.side}${comment.line ? ` line${(comment.endLine ?? comment.line) !== comment.line ? 's' : ''} ${comment.line}${(comment.endLine ?? comment.line) !== comment.line ? `–${comment.endLine}` : ''}` : ''}${stale ? ' · outdated revision' : ''}${comment.sentAt ? ' · sent to agent' : ''}`), el('p', '', comment.text)); return node;
}
function renderComments() {feedObserver?.disconnect(); ++renderVersion; const main = $('#content'); main.replaceChildren(el('h1', '', 'Review comments'), button('Export comments', async () => {const data = await api('export'); const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], {type: 'application/json'})); const link = el('a'); link.href = url; link.download = 'review-comments.json'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);})); if (!state.session.comments.length) main.append(el('div', 'empty', 'Click a line number or drag across line numbers to leave an inline comment.')); state.session.comments.forEach(c => main.append(commentNode(c)));}
function statsTable(heading, rows, max) {
  const table = el('table', 'stats-table'), head = el('tr');
  head.append(...[heading, 'Files', 'Added', 'Removed', 'Net', ''].map(text => el('th', '', text)));
  table.append(el('thead'), el('tbody')); table.tHead.append(head);
  table.tBodies[0].append(...rows.map(row => {
    const line = el('tr'), bar = el('span', 'stats-bar');
    bar.style.width = `${max ? 100 * (row.added + row.deleted) / max : 0}%`;
    bar.style.setProperty('--added', `${row.added + row.deleted ? 100 * row.added / (row.added + row.deleted) : 0}%`);
    const share = el('td', 'stats-share'); share.append(bar);
    line.append(el('th', '', row.label), el('td', '', row.files.toLocaleString()), el('td', row.added ? 'added' : '', signed(row.added)), el('td', row.deleted ? 'removed' : '', signed(-row.deleted)), el('td', '', signed(row.added - row.deleted)), share);
    return line;
  }));
  return table;
}
function renderStats() {
  feedObserver?.disconnect(); ++renderVersion;
  // Filtered files count only while “Show filtered files” is on, matching the Changes feed.
  const filtered = state.files.filter(hidden).length, included = $('#show-hidden').checked ? state.files : state.files.filter(file => !hidden(file));
  const stats = diffStats(included), main = $('#content'), summary = el('div', 'stats-summary');
  const tile = (label, value, className = '') => {const node = el('div', 'stats-tile'); node.append(el('strong', className, value), el('span', '', label)); return node;};
  summary.append(tile('changed files', stats.files.toLocaleString()), tile('lines added', signed(stats.added), 'added'), tile('lines removed', signed(-stats.deleted), 'removed'), tile('net lines', signed(stats.added - stats.deleted)));
  const notes = [`${stats.created} added · ${stats.modified} modified · ${stats.removed} deleted`];
  if (stats.uncounted) notes.push(`${stats.uncounted} binary or oversized file${stats.uncounted === 1 ? ' has' : 's have'} no line counts`);
  if (filtered) notes.push($('#show-hidden').checked ? `includes ${filtered} filtered file${filtered === 1 ? '' : 's'}` : `${filtered} filtered file${filtered === 1 ? '' : 's'} excluded; turn on Show filtered files to count ${filtered === 1 ? 'it' : 'them'}`);
  const max = Math.max(0, ...stats.byKind.map(row => row.added + row.deleted)), maxType = Math.max(0, ...stats.byType.map(row => row.added + row.deleted));
  main.replaceChildren(el('h1', '', 'Diff stats'), summary, el('p', 'muted', notes.join(' · ')));
  if (!stats.files) {main.append(el('div', 'empty', state.files.length ? 'Every change is filtered out. Turn on Show filtered files to count them.' : 'No changes to review.')); return;}
  main.append(el('h2', 'comments-title', 'By kind'), statsTable('Kind', stats.byKind, max), el('h2', 'comments-title', 'By file type'), statsTable('Type', stats.byType, maxType));
}
// Changed UI paths with neither a recording nor the agent's reason for skipping one.
function demoMissing(demos) {return Boolean(demos?.uiPaths.length && !demos.total && !demos.skipped);}
function uiChanges(demos) {const count = demos.uiPaths.length; return count === 1 ? '1 changed file affects' : `${count} changed files affect`;}
function formatDuration(seconds) {const total = Math.round(seconds); return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;}
function formatBytes(bytes) {return bytes >= 1e6 ? `${(bytes / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1e3))} kB`;}
function demoInteraction(demo) {
  const item = state.iterations.find(i => i.id === demo.iteration);
  return item ? `Iteration ${item.number}` : demo.iteration && demo.iteration === state.pendingIteration?.id ? 'Current interaction' : 'Outside recorded interactions';
}
async function openDemos(ids) {
  const result = await api('demos/open', {ids});
  notice(`Opened ${result.opened === 1 ? 'the demo' : `${result.opened} demos`} in QuickTime Player.`);
}
// Players survive re-renders, so polling for a running recording never interrupts playback.
const demoPlayers = new Map();
function demoPlayer(demo) {
  if (!demo.available || !demo.src) return el('div', 'demo-missing', demo.available ? 'Reload the page to play this demo here.' : 'The recording file is missing from the review store.');
  let video = demoPlayers.get(demo.src);
  if (!video) {
    video = el('video');
    video.controls = true; video.preload = 'metadata'; video.playsInline = true; video.src = demo.src;
    demoPlayers.set(demo.src, video);
  }
  video.title = demo.title;
  return video;
}
function renderDemos() {
  feedObserver?.disconnect(); ++renderVersion;
  const demos = state.demos, items = demos.items, main = $('#content');
  main.replaceChildren(el('h1', '', 'Demo recordings'), el('p', 'muted', 'Recordings of the running app that show this change working. Play them here or in QuickTime Player. They are kept outside the diff, after the worktree is removed too.'));
  if (demos.recording) main.append(el('div', 'demo-note', `Recording “${demos.recording.title}” on ${demos.recording.device}…`));
  if (demoMissing(demos)) main.append(el('div', 'demo-note attention', `${uiChanges(demos)} the app UI, but no demo is attached. Ask the agent to record each scenario before you approve.`));
  else if (demos.skipped && !demos.total) main.append(el('div', 'demo-note', `No demo recorded. The agent's reason: ${demos.skipped.reason}`));
  const shown = new Set(items.map(d => d.src));
  for (const src of demoPlayers.keys()) if (!shown.has(src)) demoPlayers.delete(src);
  if (!items.length) {main.append(el('div', 'empty', demos.total ? 'No demos were recorded during this scope. Full diff lists every demo.' : 'No demo recordings yet.')); return;}
  if (items.length > 1) {
    const actions = el('div', 'demo-actions'), all = button(`Open all ${items.length} in QuickTime Player`, () => openDemos(items.filter(d => d.available).map(d => d.id)));
    all.disabled = !demos.canOpen || !items.some(d => d.available);
    actions.append(all); main.append(actions);
  }
  const grid = el('div', 'demo-grid');
  grid.append(...items.map(demo => {
    const card = el('section', 'demo'), info = el('div', 'demo-info');
    const appearance = demo.appearance && demo.appearance[0].toUpperCase() + demo.appearance.slice(1);
    info.append(el('strong', '', demo.title), el('small', '', [formatDuration(demo.durationSeconds), formatBytes(demo.bytes), demoInteraction(demo), demo.device, appearance, new Date(demo.recordedAt).toLocaleString()].filter(Boolean).join(' · ')));
    const quickTime = button('Open in QuickTime Player', () => openDemos([demo.id]), 'quicktime');
    quickTime.disabled = !demos.canOpen || !demo.available;
    quickTime.title = !demo.available ? 'The recording file is missing from the review store' : demos.canOpen ? `Play ${demo.title} in QuickTime Player` : 'QuickTime Player requires macOS';
    card.append(demoPlayer(demo), info, quickTime);
    return card;
  }));
  main.append(grid);
}
function renderJob() {feedObserver?.disconnect(); ++renderVersion; const main = $('#content'), atEnd = main.scrollHeight - main.scrollTop - main.clientHeight < 100; const log = el('pre', 'log', state.job.log); main.replaceChildren(el('div', 'merge-status', state.job.status === 'merged' ? `Merged into ${state.target}. Worktrunk cleanup has been requested.` : state.job.status === 'failed' ? 'Merge stopped. Your changes are available; inspect the log.' : 'Validating and merging…'), log); if (state.job.status === 'failed') main.append(button('Return to review', () => load(true))); if (atEnd) main.scrollTop = main.scrollHeight;}
// The next unreviewed file below, wrapping around to the top of the shown list.
function nextUnviewed(files, id) {
  const index = files.findIndex(f => f.id === id);
  return [...files.slice(index + 1), ...files.slice(0, Math.max(index, 0))].find(f => f.id !== id && !viewed(f))?.id;
}
async function markAndNext(id = active) {
  const files = visibleFiles();
  state = await api('viewed', {file: id, fingerprint: state.files.find(f => f.id === id).fingerprint, viewed: true});
  const next = nextUnviewed(files, id);
  updateChrome();
  if (!next) notice('Every shown file is reviewed.');
  if ($('#only-unviewed').checked) {active = next || id; await load();} else if (next) await selectFile(next);
}
$('#iteration').onchange = () => run(async () => {checkpointReviewTime(); iteration = $('#iteration').value || null; sampleReviewTime(); active = null; $('#content').replaceChildren(); const url = new URL(location.href); if (iteration) url.searchParams.set('iteration', iteration); else url.searchParams.delete('iteration'); history.replaceState(null, '', url); await load();});
window.addEventListener('popstate', () => run(async () => {checkpointReviewTime(); iteration = new URLSearchParams(location.search).get('iteration'); sampleReviewTime(); active = null; await load();}));
$('#refresh').onclick = () => run(() => load(true));
$('#simulator').onclick = () => run(async () => {
  simulatorOpening = true; updateChrome(); notice('Opening worktree Simulator…');
  try {const result = await api('simulator', {}); notice(`Opened ${result.simulator.name}.`);}
  finally {simulatorOpening = false; updateChrome();}
});
$('#dev-menu').onclick = () => run(async () => {
  devMenuTriggering = true; updateChrome(); notice('Opening worktree Simulator and triggering Dev Menu…');
  try {const result = await api('simulator/dev-menu', {}); notice(`Opened ${result.simulator.name} and sent shake.`);}
  finally {devMenuTriggering = false; updateChrome();}
});
let runDestinations;
function runSummary(last) {
  const name = last.destination.name;
  return {running: `Building and launching on ${name}…`, succeeded: `Launched on ${name}.`, cancelled: `Cancelled the run on ${name}.`,
          failed: `The run on ${name} failed with exit status ${last.exitCode}. The output below shows why.`,
          ended: `The run on ${name} ended while the review server restarted, so its result is unknown.`}[last.status] || last.status;
}
function renderRunDestinations() {
  const list = $('#run-destinations'), running = state.run?.last?.status === 'running';
  if (!runDestinations) return;
  if (!runDestinations.length) {list.replaceChildren(el('p', 'muted', 'No destinations are available. Connect a device or create a simulator, then refresh the list.')); return;}
  list.replaceChildren(...runDestinations.map(destination => {
    const node = button('', () => startRun(destination), 'run-destination'), text = el('span');
    text.append(el('strong', '', destination.name));
    if (destination.detail) text.append(el('small', '', destination.detail));
    node.append(text);
    if (destination.kind) node.append(el('em', '', destination.kind));
    node.disabled = running || !state.run?.available;
    node.title = running ? 'Wait for the current run to finish, or cancel it' : `Build and launch on ${destination.name}`;
    return node;
  }));
}
async function loadRunDestinations() {
  runDestinations = null;
  $('#run-destinations').replaceChildren(el('p', 'muted', 'Looking for devices and simulators…'));
  try {runDestinations = (await api('run/destinations')).destinations; renderRunDestinations();}
  catch (error) {$('#run-destinations').replaceChildren(el('p', 'muted', error.message));}
}
async function updateRunLog() {
  const log = $('#run-log');
  if (!state.run?.last) {log.hidden = true; return;}
  const response = await fetch('/api/' + scopedPath('run/log'), {headers: {'X-Review-Token': token || ''}});
  if (!response.ok) return;
  const atEnd = log.scrollHeight - log.scrollTop - log.clientHeight < 40, text = await response.text();
  log.hidden = false;
  if (log.textContent !== text) {log.textContent = text; if (atEnd) log.scrollTop = log.scrollHeight;}
}
function renderRun() {
  const last = state.run?.last, status = $('#run-status');
  status.hidden = !last;
  if (last) {status.className = last.status; $('#run-summary').textContent = runSummary(last); $('#run-cancel').hidden = last.status !== 'running';}
  renderRunDestinations();
  if ($('#run-dialog').open) run(updateRunLog);
}
async function startRun(destination) {
  state = await api('run', {destination: destination.id});
  updateChrome(); renderRun();
}
$('#run').onclick = () => {$('#run-dialog').showModal(); renderRun(); run(loadRunDestinations);};
$('#run-reload').onclick = () => run(loadRunDestinations);
$('#run-cancel').onclick = () => run(async () => {state = await api('run/cancel', {}); updateChrome(); renderRun();});
$('#rank').onclick = () => run(async () => {state = await api('rank', {}); updateChrome();});
for (const id of ['search', 'show-hidden', 'only-unviewed']) $('#' + id).addEventListener(id === 'search' ? 'input' : 'change', () => run(() => load()));
$('#mode').onchange = () => run(async () => {state = await api('settings', {diffMode: $('#mode').value}); await load();});
document.querySelectorAll('[data-tab]').forEach(node => node.onclick = () => run(async () => {tab = node.dataset.tab; await load();}));
document.querySelectorAll('[data-close]').forEach(node => node.onclick = () => node.closest('dialog').close());
$('#settings').onclick = () => {const form = $('#defaults-form'), s = state.settings; for (const key of ['hideLocalization', 'hideTests', 'hideViews', 'hideManifests', 'hideGenerated']) form.elements[key].checked = s[key]; form.elements.exclude.value = s.exclude.join('\n'); form.elements.imageScale.value = s.imageScale; form.elements.rubric.value = s.rubric; $('#scale-label').textContent = s.imageScale + '%'; $('#defaults-dialog').showModal();};
$('#defaults-form').elements.imageScale.oninput = event => $('#scale-label').textContent = event.target.value + '%';
$('#defaults-form').onsubmit = event => {event.preventDefault(); run(async () => {const form = event.target, settings = {}; for (const key of ['hideLocalization', 'hideTests', 'hideViews', 'hideManifests', 'hideGenerated']) settings[key] = form.elements[key].checked; settings.exclude = form.elements.exclude.value.split('\n').map(s => s.trim()).filter(Boolean); settings.imageScale = Number(form.elements.imageScale.value); settings.rubric = form.elements.rubric.value; state = await api('settings', settings); $('#defaults-dialog').close(); await load();});};
$('#comment-form').onkeydown = event => {
  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey) && !event.isComposing) {
    event.preventDefault();
    if (!event.currentTarget.querySelector('.primary').disabled) event.currentTarget.requestSubmit();
  }
};
$('#comment-form').onsubmit = event => {
  event.preventDefault();
  const form = event.target, submit = form.querySelector('.primary');
  if (submit.disabled) return;
  submit.disabled = true;
  const target = {...commentTarget};
  run(async () => {
    try {
      state = await api('comment', {...target, ...(target.side === 'file' ? {} : {line: Number(form.elements.startLine.value), endLine: Number(form.elements.endLine.value)}), text: form.elements.text.value});
      $('#comment-dialog').close();
      await updateFileComments(target.file);
    } finally {submit.disabled = false;}
  });
};
function feedbackDate(value) {const date = new Date(value); return Number.isNaN(date.getTime()) ? value : date.toLocaleString();}
async function loadFeedback() {
  const inbox = await api('feedback'), open = inbox.entries.filter(entry => entry.status !== 'implemented'), implemented = inbox.entries.filter(entry => entry.status === 'implemented');
  $('#feedback').textContent = open.length ? `Tool feedback · ${open.length}` : 'Tool feedback';
  $('#feedback-directory').textContent = `Saved in ${inbox.directory}. Survives worktree removal; shared across this repository.`;
  $('#feedback-open-count').textContent = open.length;
  $('#feedback-implemented-count').textContent = implemented.length;
  document.querySelectorAll('[data-feedback-tab]').forEach(node => {node.classList.toggle('selected', node.dataset.feedbackTab === feedbackTab); node.setAttribute('aria-selected', String(node.dataset.feedbackTab === feedbackTab));});
  const entries = feedbackTab === 'open' ? open : implemented;
  $('#feedback-list').replaceChildren(...entries.map(entry => {
    const node = el('div', 'comment feedback-entry' + (entry.status === 'implemented' ? ' implemented' : ''));
    node.append(button(entry.status === 'implemented' ? 'Reopen' : 'Mark implemented', async () => {await api('feedback/status', {id: entry.id, implemented: entry.status !== 'implemented'}); await loadFeedback();}));
    node.append(el('small', '', `${feedbackDate(entry.createdAt)} · ${entry.branch || 'Detached HEAD'}${entry.path ? ` · ${entry.path}` : ''}`), el('p', '', entry.text));
    if (entry.status === 'implemented') node.append(el('small', 'feedback-implemented', `Implemented ${entry.implementedAt ? feedbackDate(entry.implementedAt) : ''}${entry.implementedBranch ? ` on ${entry.implementedBranch}` : ''}`));
    return node;
  }));
  $('#feedback-empty').textContent = feedbackTab === 'open' ? 'No open tool feedback.' : 'No implemented feedback yet. Mark an entry implemented to move it here.';
  $('#feedback-empty').hidden = Boolean(entries.length);
  return inbox;
}
document.querySelectorAll('[data-feedback-tab]').forEach(node => node.onclick = () => run(async () => {feedbackTab = node.dataset.feedbackTab; await loadFeedback();}));
$('#feedback').onclick = () => run(async () => {
  feedbackTab = 'open'; await loadFeedback(); $('#feedback-form').reset(); $('#feedback-dialog').showModal(); $('#feedback-form').elements.text.focus();
});
$('#feedback-form').onsubmit = event => {event.preventDefault(); run(async () => {
  const submit = event.target.querySelector('.primary'); submit.disabled = true;
  try {await api('feedback', {text: event.target.elements.text.value}); event.target.reset(); feedbackTab = 'open'; await loadFeedback(); notice('Tool feedback saved in the shared repository inbox.');}
  finally {submit.disabled = false;}
});};
$('#feedback-export').onclick = () => run(async () => {
  const inbox = await loadFeedback(), url = URL.createObjectURL(new Blob([JSON.stringify(inbox.entries, null, 2)], {type: 'application/json'})), link = el('a');
  link.href = url; link.download = 'review-tool-feedback.json'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});
function flash(node) {node.classList.remove('flash'); void node.offsetWidth; node.classList.add('flash');}
async function loadDefinitions() {
  definitionNames = new Set((await api('definitions')).names);
  markDefinitionLinks(document);
}
// Only Swift type names declared somewhere in this repository become links; imports name modules, not types.
function markDefinitionLinks(root) {
  for (const node of root.querySelectorAll('code[data-language="swift"] .tok-type')) {
    if (!definitionNames.has(node.textContent) || node.classList.contains('definition-link') || /^\s*(?:@\w+\s+)*import\s/.test(node.parentElement.textContent)) continue;
    node.classList.add('definition-link'); node.title = `Click for Jump to Definition · ${navigator.platform.startsWith('Mac') ? '⌘' : 'Ctrl'}-click to jump`;
  }
}
// Method declarations offer their call sites; names alone cannot tell overloads or receivers apart.
function markCallerLinks(root) {
  for (const node of root.querySelectorAll('code[data-language="swift"] .tok-function')) {
    let previous = node.previousSibling;
    while (previous?.nodeType === Node.TEXT_NODE && !previous.textContent.trim()) previous = previous.previousSibling;
    if (node.classList.contains('caller-link') || !previous?.classList?.contains('tok-keyword') || previous.textContent !== 'func') continue;
    node.classList.add('caller-link'); node.title = 'Click to show callers';
  }
}
function closeDefinitionMenu() {definitionMenu?.remove(); definitionMenu = null;}
function placeMenu(menu, link) {
  const rect = link.getBoundingClientRect();
  menu.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - menu.offsetWidth - 8))}px`;
  menu.style.top = `${rect.bottom + menu.offsetHeight + 8 > window.innerHeight ? Math.max(8, rect.top - menu.offsetHeight - 4) : rect.bottom + 4}px`;
}
async function showCallersMenu(link, name, fromPath) {
  closeDefinitionMenu();
  const menu = definitionMenu = el('div', 'definition-menu'), status = el('small', '', 'Searching Swift files…');
  menu.setAttribute('role', 'menu');
  menu.append(el('strong', '', `Callers of ${name}`), status);
  (link.closest('dialog') || document.body).append(menu);
  placeMenu(menu, link);
  const result = await api('callers?name=' + encodeURIComponent(name));
  if (menu !== definitionMenu) return;
  const callers = rankDefinitions(result.results, fromPath);
  status.textContent = callers.length ? `${callers.length}${result.truncated ? '+' : ''} call site${callers.length === 1 ? '' : 's'} by name · closest first` : `No calls to ${name} found in Swift files`;
  menu.append(...callers.map(caller => {
    const option = button('', async () => {closeDefinitionMenu(); await openSource(caller.path, caller.line);}, 'definition-option');
    option.setAttribute('role', 'menuitem'); option.title = caller.path;
    option.append(el('span', '', `${caller.path.split('/').pop()}:${caller.line}`), el('small', '', caller.text));
    return option;
  }));
  placeMenu(menu, link);
  menu.querySelector('.definition-option')?.focus();
}
async function definitionLocations(name, fromPath) {return rankDefinitions((await api('definition?name=' + encodeURIComponent(name))).locations, fromPath);}
async function jumpToDefinition(name, fromPath) {
  const locations = await definitionLocations(name, fromPath);
  if (!locations.length) throw new Error(`No declaration of ${name} found in this repository`);
  await openSource(locations[0].path, locations[0].line);
  if (locations.length > 1) notice(`${name} is declared ${locations.length} times; opened the one closest to ${fromPath.split('/').pop()}. Click the name for the full list.`);
}
function showDefinitionMenu(link, name, fromPath) {
  closeDefinitionMenu();
  const menu = definitionMenu = el('div', 'definition-menu');
  menu.setAttribute('role', 'menu');
  menu.append(el('strong', '', name));
  const jump = button('Jump to definition', async () => {
    const locations = await definitionLocations(name, fromPath);
    if (menu !== definitionMenu) return;
    if (locations.length === 1) {closeDefinitionMenu(); await openSource(locations[0].path, locations[0].line); return;}
    jump.remove();
    menu.append(el('small', '', `${locations.length} declarations · closest first`), ...locations.map(location => {
      const option = button('', async () => {closeDefinitionMenu(); await openSource(location.path, location.line);}, 'definition-option');
      option.append(el('span', '', `${location.path.split('/').pop()}:${location.line}`), el('small', '', `${location.kind} · ${location.path}`));
      return option;
    }));
    menu.querySelector('.definition-option')?.focus();
  });
  jump.setAttribute('role', 'menuitem');
  menu.append(jump);
  (link.closest('dialog') || document.body).append(menu);
  placeMenu(menu, link);
  jump.focus();
}
document.addEventListener('click', event => {
  const link = event.target.closest?.('.definition-link, .caller-link');
  if (!link) {if (definitionMenu && !definitionMenu.contains(event.target)) closeDefinitionMenu(); return;}
  event.preventDefault(); event.stopPropagation();
  const fromPath = link.closest('[data-path]')?.dataset.path || '';
  if (link.classList.contains('caller-link')) {run(() => showCallersMenu(link, link.textContent, fromPath)); return;}
  if (event.metaKey || event.ctrlKey) {closeDefinitionMenu(); run(() => jumpToDefinition(link.textContent, fromPath));}
  else showDefinitionMenu(link, link.textContent, fromPath);
});
function closeDefinitionMenuOnEscape(event) {if (event.key === 'Escape' && definitionMenu) {event.preventDefault(); closeDefinitionMenu();}}
document.addEventListener('keydown', closeDefinitionMenuOnEscape, true);
for (const id of ['content', 'source-body']) $('#' + id).addEventListener('scroll', closeDefinitionMenu);
let searchVersion = 0, searchTimer;
const SEARCH_HINT = 'Plain text, case-insensitive unless Match case is on. Diff and Changed files follow the selected review scope and include filtered files.';
const SEARCH_SCOPES = {diff: 'the diff', files: 'changed files', project: 'the project'};
function markedText(text, query, matchCase) {
  const code = el('code'), haystack = matchCase ? text : text.toLowerCase(), needle = matchCase ? query : query.toLowerCase();
  let start = 0;
  for (let index = haystack.indexOf(needle); index >= 0 && needle; index = haystack.indexOf(needle, start)) {
    code.append(document.createTextNode(text.slice(start, index)), el('mark', '', text.slice(index, index + needle.length)));
    start = index + needle.length;
  }
  code.append(document.createTextNode(text.slice(start)));
  return code;
}
async function runCodeSearch() {
  const form = $('#search-form'), query = form.elements.q.value, scope = form.elements.scope.value, matchCase = form.elements.case.checked, version = ++searchVersion;
  if (!query) {$('#search-summary').textContent = SEARCH_HINT; $('#search-results').replaceChildren(); return;}
  $('#search-summary').textContent = 'Searching…';
  const result = await api(`search?q=${encodeURIComponent(query)}&scope=${scope}&case=${matchCase ? 1 : 0}`);
  if (version !== searchVersion) return;
  const groups = Map.groupBy(result.results, match => match.path);
  $('#search-summary').textContent = result.results.length
    ? `${result.results.length}${result.truncated ? '+' : ''} match${result.results.length === 1 ? '' : 'es'} in ${groups.size} file${groups.size === 1 ? '' : 's'}${result.truncated ? ' · showing the first results; refine the search' : ''}`
    : `No matches in ${SEARCH_SCOPES[scope]}.`;
  $('#search-results').replaceChildren(...[...groups].map(([path, matches]) => {
    const group = el('section', 'search-group'), heading = el('div', 'search-file');
    heading.append(el('strong', '', path.split('/').pop()), el('small', '', path));
    const module = moduleFor(path); if (module) heading.append(el('span', `module-tag module-color-${moduleColorMap.get(module.name) ?? 0}`, moduleLabel(module)));
    group.append(heading, ...matches.map(match => {
      const file = match.file && state.files.find(f => f.id === match.file);
      const option = button('', () => file ? showInDiff(file, match.line, match.side) : openSource(match.path, match.line), 'search-match' + (match.side === 'old' ? ' removed-line' : ''));
      option.title = file ? `Show ${match.side === 'old' ? 'removed' : ''} line ${match.line} in the diff` : `Open ${match.path}:${match.line}`;
      option.append(el('span', 'source-number', match.side === 'old' ? `−${match.line}` : match.line), markedText(match.text, query, matchCase));
      return option;
    }));
    return group;
  }));
}
function openCodeSearch() {
  const form = $('#search-form'), selection = String(getSelection() || '').trim();
  if (selection && !selection.includes('\n') && selection.length <= 200) form.elements.q.value = selection;
  if (!$('#search-dialog').open) $('#search-dialog').showModal();
  form.elements.q.focus(); form.elements.q.select();
  run(runCodeSearch);
}
$('#code-search').onclick = openCodeSearch;
$('#search-form').onsubmit = event => {event.preventDefault(); clearTimeout(searchTimer); run(runCodeSearch);};
$('#search-form').elements.q.oninput = () => {clearTimeout(searchTimer); searchTimer = setTimeout(() => run(runCodeSearch), 250);};
$('#search-form').onchange = event => {if (event.target.name !== 'q') run(runCodeSearch);};
function openCodeSearchOnShortcut(event) {if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.key.toLowerCase() === 'f') {event.preventDefault(); openCodeSearch();}}
document.addEventListener('keydown', openCodeSearchOnShortcut);
async function sourceFor(path) {
  if (!sources.has(path)) sources.set(path, api('source?path=' + encodeURIComponent(path)).catch(error => {sources.delete(path); throw error;}));
  return sources.get(path);
}
async function openSource(path, line, remember = true) {
  const source = await sourceFor(path), dialog = $('#source-dialog');
  if (remember) sourceHistory.push({path, line});
  $('#source-name').textContent = path.split('/').pop();
  $('#source-path').textContent = `${path}:${line} · current worktree`;
  const module = moduleFor(path), moduleSlot = $('#source-module');
  moduleSlot.replaceChildren(); if (module) moduleSlot.append(el('span', `module-tag module-color-${moduleColorMap.get(module.name) ?? 0}`, moduleLabel(module)));
  $('#source-back').disabled = sourceHistory.length < 2;
  const reviewed = state.files.find(file => file.path === path && !file.binary);
  $('#source-in-diff').hidden = !reviewed;
  $('#source-in-diff').onclick = () => run(() => showInDiff(reviewed, line));
  const language = languageFor(path, source.lines[0]), highlighted = highlightLines(source.lines, language);
  const body = $('#source-body'); body.dataset.path = path;
  body.replaceChildren(...source.lines.map((text, index) => {
    const row = el('div', 'source-line' + (index + 1 === line ? ' target-line' : ''));
    row.append(el('span', 'source-number', index + 1), codeNode(highlighted[index], text, language));
    return row;
  }));
  markDefinitionLinks(body); markCallerLinks(body);
  if (!dialog.open) dialog.showModal();
  body.querySelector('.target-line')?.scrollIntoView({block: 'center'});
}
$('#source-back').onclick = () => run(async () => {sourceHistory.pop(); const previous = sourceHistory.at(-1); if (previous) await openSource(previous.path, previous.line, false);});
$('#source-dialog').addEventListener('close', () => {sourceHistory = []; closeDefinitionMenu();});
async function showInDiff(file, line, side = 'new') {
  $('#source-dialog').close(); $('#search-dialog').close();
  if (tab !== 'all') tab = 'all';
  if (hidden(file)) $('#show-hidden').checked = true;
  $('#search').value = ''; $('#only-unviewed').checked = false;
  if (line) {
    await linesFor(file);
    const data = await api('file?id=' + file.id);
    expansions.set(expansionKey(file), expandAll(contextGaps(data.rows, data.oldCount, data.newCount)));
  }
  pendingLine = line ? {file: file.id, line, side} : null; active = file.id;
  await load();
}
$('#send-review').onclick = () => {
  const unsent = state.handoff.unsent;
  $('#send-heading').textContent = `Send review to ${agentName(state.agent)}`;
  $('#send-summary').textContent = unsent ? `Send ${unsent} new unresolved comment${unsent === 1 ? '' : 's'} from every review scope. Resolved comments and comments sent earlier stay here.` : 'No new comments. Write a note to send one anyway.';
  $('#send-agent-note').textContent = state.agent?.provider === 'codex'
    ? 'Queues feedback in the Codex conversation that wrote this change, including when it is open in the desktop app. Follow its reply there. It never merges.'
    : 'Resumes the Claude conversation that wrote this change, in the background. It records its work as a new interaction; it never merges.';
  $('#send-form').reset(); $('#send-dialog').showModal(); $('#send-form').elements.note.focus();
};
$('#send-form').onsubmit = event => {
  event.preventDefault();
  run(async () => {
    const submit = event.target.querySelector('.primary'); submit.disabled = true;
    try {state = await api('review/send', {note: event.target.elements.note.value}); $('#send-dialog').close(); updateChrome(); notice(`Submitted your review to ${agentName(state.agent)}.`);}
    finally {submit.disabled = false;}
  });
};
let mergeRevision;
$('#approve').onclick = () => {
  mergeRevision = state.merge.revision;
  $('#merge-description').textContent = `Ask the agent to merge the full ${state.branch} branch into ${state.target}?`;
  $('#merge-summary').textContent = `Approve all ${state.merge.fileCount} files in the full diff, including filtered files. The agent will first update from the latest ${state.target}, then handle comments, fix failing checks and resolve conflicts, then merge with one final commit. These corrections are covered by your approval; you do not need to resolve comment flags or approve again.`;
  if (demoMissing(state.demos)) $('#merge-summary').textContent += ` No demo recording is attached, although ${uiChanges(state.demos)} the app UI.`;
  $('#merge-agent-note').textContent = state.agent ? `Saves your approval and sends the merge request to the ${agentName(state.agent)} conversation that wrote this change, just like review comments. Follow its progress and reply there. Commit notes are optional; the agent will finalize them.` : 'Start review from your Codex or Claude session so the merge can be handed to the correct agent.';
  const form = $('#merge-form');
  form.elements.title.value = state.merge.draft.title;
  form.elements.description.value = state.merge.draft.description;
  $('#merge-dialog').showModal();
};
$('#merge-form').onsubmit = event => {
  event.preventDefault();
  run(async () => {
    const form = event.target, submit = form.querySelector('.primary'); submit.disabled = true;
    try {
      state = await api('merge', {revision: mergeRevision, title: form.elements.title.value, description: form.elements.description.value});
      $('#merge-dialog').close(); updateChrome(); notice('Approval saved. The merge request will be sent to the original agent conversation when its queue turn begins.');
    } finally {submit.disabled = false;}
  });
};
document.addEventListener('keydown', event => {if (document.querySelector('dialog[open]') || /INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName) || event.metaKey || event.ctrlKey || event.altKey) return; run(async () => {const files = visibleFiles(), index = files.findIndex(f => f.id === active); if (event.key.toLowerCase() === 'j' && files[index + 1]) await selectFile(files[index + 1].id); if (event.key.toLowerCase() === 'k' && files[index - 1]) await selectFile(files[index - 1].id); if (event.key.toLowerCase() === 'v' && active) await markAndNext(); if (event.key.toLowerCase() === 's') {tab = tab === 'snapshot' ? 'all' : 'snapshot'; await load();}});});
setInterval(() => {if (!state || !(mergeLogRunning || state.job.status === 'running' || state.ranking?.status === 'running' || state.mergeRequest?.status === 'pending' || state.mergeRequest?.status === 'working' || state.handoff?.last?.status === 'running' || state.demos?.recording || state.run?.last?.status === 'running')) return; run(async () => {const version = loadVersion, scope = iteration, nextState = await api('state'); if (version !== loadVersion || scope !== iteration) return; const demos = JSON.stringify(state.demos), runStatus = state.run?.last?.status; state = nextState; updateChrome(); if ($('#run-dialog').open || runStatus !== state.run?.last?.status) renderRun(); if (runStatus === 'running' && state.run?.last?.status !== 'running') notice(runSummary(state.run.last)); if (state.job.status !== 'idle') renderJob(); else if (tab === 'demos' && JSON.stringify(state.demos) !== demos) renderDemos();});}, 1500);
run(loadFeedback);
run(async () => {await load(); if (!state.jevAvailable) notice('Jev is unavailable without JEV_API_KEY in the review server environment. Files use clearly labeled fallback scores.');});

const reviewTimer = new ReviewTime(async body => {
  const response = await fetch('/api/' + scopedPath('review-time', null), {method: 'POST', keepalive: true,
    headers: {'X-Review-Token': token || '', 'Content-Type': 'application/json'}, body: JSON.stringify(body)});
  if (!response.ok) throw new Error('Review timing could not be saved');
  const totals = await response.json();
  if (state) {state.reviewTime = totals; updateReviewTime();}
});
// Merge progress is not review: approval ends the reviewer's part, and agents may watch the page while merging.
function reviewTimePaused() {return Boolean(watchedMerge || ['pending', 'working', 'merged'].includes(state?.mergeRequest?.status) || ['running', 'merged'].includes(state?.job?.status));}
function sampleReviewTime() {reviewTimer.update(document.visibilityState === 'visible', document.hasFocus(), iteration || 'full', reviewTimePaused());}
function reviewInput(event) {if (event.isTrusted) reviewTimer.input();}
// Ignore zero-movement pointer events that browsers synthesize when content scrolls under a still cursor.
window.addEventListener('pointermove', event => {if (event.movementX || event.movementY) reviewInput(event);}, {passive: true});
for (const type of ['pointerdown', 'keydown', 'wheel', 'touchstart']) window.addEventListener(type, reviewInput, {capture: true, passive: true});
function checkpointReviewTime() {sampleReviewTime(); void reviewTimer.flush();}
window.addEventListener('focus', sampleReviewTime);
window.addEventListener('blur', checkpointReviewTime);
document.addEventListener('visibilitychange', checkpointReviewTime);
window.addEventListener('pagehide', () => {reviewTimer.update(false, false, iteration || 'full'); void reviewTimer.flush();});
window.addEventListener('pageshow', sampleReviewTime);
document.addEventListener('freeze', () => {reviewTimer.update(false, false, iteration || 'full'); void reviewTimer.flush();});
document.addEventListener('resume', sampleReviewTime);
setInterval(sampleReviewTime, 1000);
setInterval(checkpointReviewTime, 5000);
sampleReviewTime();
