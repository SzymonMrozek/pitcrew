// Comment mode: point at anything on the review page and leave tool feedback that says what was there.
const LIMITS = {text: 400, code: 400, value: 400, componentText: 1000, selector: 1000, path: 1000, activeFile: 1000, html: 2000}, NAME_LIMIT = 80;
const CONTROLS = [['button', 'Button'], ['a', 'Link'], ['summary', 'Disclosure'], ['select', 'Picker'], ['textarea', 'Text field'], ['input', 'Field'], ['label', 'Label']];
// Outermost first. Anything unnamed here still records its selector, text and markup.
export const COMPONENTS = [
  ['header', 'Header'], ['.iteration-bar', 'Scope bar'], ['#iteration-context', 'Scope context'], ['.toolbar', 'Toolbar'], ['.tabs', 'Tabs'],
  ['#notice', 'Notice'], ['#merge-request-status', 'Merge status'], ['#review-handoff-status', 'Handoff status'], ['#merge-progress', 'Merge agent output'],
  ['aside', 'File sidebar'], ['#filtered-files', 'Filtered files'], ['.file-button', 'File row'], ['.keyboard-hint', 'Keyboard hint'],
  ['.review-file', 'Changed file'], ['.file-header', 'File header'], ['.file-actions', 'File actions'], ['.diff-box', 'Diff'], ['.diff-tools', 'Diff tools'],
  ['.diff-row', 'Diff row'], ['.gap-row', 'Collapsed context'], ['.line-number', 'Line number'],
  ['.image-grid', 'Snapshot comparison'], ['.image-panel', 'Snapshot panel'], ['.snapshot-tools', 'Snapshot tools'],
  ['.summary', 'Summary'], ['.summary-section', 'Summary section'], ['.summary-graph-frame', 'Module graph'], ['.hotspots', 'Hotspots'], ['.change-grid', 'Change cards'],
  ['.demo-grid', 'Demos'], ['.demo', 'Demo'], ['.stats-summary', 'Stats tiles'], ['.stats-tile', 'Stats tile'], ['.stats-table', 'Stats table'],
  ['.comment', 'Comment'], ['.comment-reply', 'Comment reply'], ['.merge-status', 'Merge status'], ['.search-group', 'Search result'], ['.source-line', 'Source line'],
];
const ancestors = node => {const nodes = []; for (; node; node = node.parentElement) nodes.unshift(node); return nodes;};
const clean = value => String(value ?? '').replace(/\s+/g, ' ').trim();
const visibleText = node => clean(node.innerText ?? node.textContent);
const accessibleName = node => clean(node.getAttribute('aria-label') || node.innerText || node.textContent || node.title || node.placeholder || node.name);
function controlName(node) {
  const tag = node.tagName.toLowerCase(), kind = CONTROLS.find(([name]) => name === tag)?.[1];
  if (!kind) return null;
  const name = accessibleName(node);
  return name ? `${kind} "${name}"` : kind;
}
function dialogName(node) {
  const dialog = node.closest('dialog');
  return dialog ? clean(dialog.querySelector('h2')?.textContent || dialog.getAttribute('aria-label') || dialog.id) : null;
}
function namedNodes(target) {
  return ancestors(target).flatMap(node => {
    const component = COMPONENTS.filter(([selector]) => node.matches(selector)).at(-1)?.[1] ?? controlName(node);
    return component ? [{node, name: component}] : [];
  });
}
function selectorPart(node) {
  const tag = node.tagName.toLowerCase();
  if (node.id) return `${tag}#${node.id}`;
  const classes = [...node.classList].filter(name => !['selected', 'flash'].includes(name)).slice(0, 2);
  return tag + classes.map(name => '.' + name).join('');
}
export function selectorPath(target) {return ancestors(target).filter(node => !['html', 'body'].includes(node.tagName.toLowerCase())).map(selectorPart).join(' > ');}
function fileContext(target) {
  const owner = target.closest('[data-file], [data-path]');
  if (!owner) return null;
  const row = target.closest('.code-cell, .source-line'), number = row?.querySelector('.line-number, .source-number');
  return {id: owner.dataset.file ?? null, path: owner.dataset.path ?? null, side: number?.dataset.side ?? null, line: Number(number?.dataset.line ?? number?.textContent) || null, code: row ? visibleText(row.querySelector('code') ?? row) : null};
}
const bounded = (key, value) => {const limit = LIMITS[key] ?? NAME_LIMIT; return typeof value === 'string' && value.length > limit ? value.slice(0, limit - 1) + '…' : value;};
// The token sits in the page's own links, so it goes first: a cut through it would leave a prefix no search can find.
const saveable = (context, token) => {const json = JSON.stringify(context); return JSON.parse(token ? json.split(token).join('[token]') : json, bounded);};
export function elementContext(target, point, view, token) {
  const named = namedNodes(target), component = named.at(-1), node = component?.node ?? target, rect = node.getBoundingClientRect();
  return saveable({
    tab: view.tabLabel, dialog: dialogName(target), component: component?.name ?? selectorPart(target), componentPath: named.map(entry => entry.name),
    selector: selectorPath(target),
    element: {tag: target.tagName.toLowerCase(), id: target.id || null, classes: [...target.classList], role: target.getAttribute('role'), name: accessibleName(target) || null, value: target.value, checked: target.checked},
    text: visibleText(target), componentText: visibleText(node), html: node.outerHTML,
    file: fileContext(target),
    pin: {x: Math.round(point.x), y: Math.round(point.y), inComponent: {x: Math.round(point.x - rect.left), y: Math.round(point.y - rect.top)}},
    rect: {x: Math.round(rect.left), y: Math.round(rect.top), width: Math.round(rect.width), height: Math.round(rect.height)},
    view,
  }, token);
}
export const feedbackWhere = context => [context.tab, context.dialog, ...(context.componentPath || [])].filter(Boolean).join(' › ');
export const isCommentShortcut = event => (event.metaKey || event.ctrlKey) && event.shiftKey && !event.altKey && event.key.toLowerCase() === 'c';
export function composerPosition(point, size, viewport, gap = 16) {
  const left = point.x + gap + size.width <= viewport.width - gap ? point.x + gap : point.x - gap - size.width;
  return {left: Math.max(gap, left), top: Math.max(gap, Math.min(point.y - 24, viewport.height - size.height - gap))};
}
export function mountElementFeedback({view, save, token}) {
  const $ = selector => document.querySelector(selector);
  const layer = $('#feedback-layer'), outline = $('#feedback-outline'), label = $('#feedback-outline-label'), pin = $('#feedback-pin'), status = $('#feedback-mode-status');
  const composer = $('#feedback-composer'), form = $('#feedback-composer-form');
  let active = false, pointer, target, submitting, swallowClick = false, saved = 0;
  const owned = node => layer.contains(node) || composer.contains(node);
  function showOutline(node) {
    const named = namedNodes(node).at(-1), rect = (named?.node ?? node).getBoundingClientRect();
    outline.hidden = false;
    Object.assign(outline.style, {left: rect.left + 'px', top: rect.top + 'px', width: rect.width + 'px', height: rect.height + 'px'});
    label.textContent = named?.name ?? selectorPart(node);
    label.classList.toggle('inside', rect.top < 26);
  }
  function track() {
    if (!pointer || composer.open) return;
    const node = document.elementFromPoint(pointer.x, pointer.y);
    if (node && !owned(node)) showOutline(node); else outline.hidden = true;
  }
  function setActive(next) {
    if (next === active) return;
    active = next; saved = 0; pointer = null; outline.hidden = true;
    document.documentElement.classList.toggle('feedback-mode', active);
    status.textContent = 'Click anything to comment on the review tool · Esc to finish';
    if (active) layer.showPopover(); else {if (composer.open) composer.close(); layer.hidePopover();}
  }
  function pick(event) {
    const node = document.elementFromPoint(event.clientX, event.clientY) ?? event.target;
    target = elementContext(node, {x: event.clientX, y: event.clientY}, view(), token);
    Object.assign(pin.style, {left: event.clientX + 'px', top: event.clientY + 'px'}); pin.hidden = false;
    $('#feedback-composer-where').textContent = feedbackWhere(target);
    $('#feedback-composer-shows').textContent = target.text || target.componentText;
    $('#feedback-composer-shows').hidden = !(target.text || target.componentText);
    form.reset(); form.querySelector('.primary').disabled = false; composer.showModal(); form.elements.text.focus();
    const {left, top} = composerPosition({x: event.clientX, y: event.clientY}, composer.getBoundingClientRect(), {width: innerWidth, height: innerHeight});
    Object.assign(composer.style, {left: left + 'px', top: top + 'px'});
  }
  // Disabled controls never get a click, so picking happens on pointerup and the click that follows is dropped.
  function block(event) {
    const swallow = swallowClick && event.type === 'click';
    if (event.type === 'pointerdown' || swallow) swallowClick = false;
    if (!swallow && (!active || composer.open)) return;
    event.preventDefault(); event.stopPropagation();
    if (event.type === 'pointerup' && event.button === 0) {swallowClick = true; pick(event);}
  }
  for (const type of ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu']) window.addEventListener(type, block, true);
  window.addEventListener('pointermove', event => {if (active) {pointer = {x: event.clientX, y: event.clientY}; track();}}, {capture: true, passive: true});
  window.addEventListener('scroll', () => {if (active) track();}, {capture: true, passive: true});
  window.addEventListener('keydown', event => {
    if (isCommentShortcut(event)) {event.preventDefault(); event.stopPropagation(); setActive(!active); return;}
    if (!active || composer.open) return;
    event.stopPropagation();
    if (event.key === 'Escape') {event.preventDefault(); setActive(false);}
  }, true);
  composer.addEventListener('close', () => {pin.hidden = true; target = null;});
  composer.addEventListener('click', event => {
    if (event.target !== composer) return;
    const rect = composer.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) composer.close();
  });
  form.elements.text.addEventListener('keydown', event => {if (event.key === 'Enter' && (event.metaKey || event.ctrlKey) && !event.isComposing) {event.preventDefault(); form.requestSubmit();}});
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (submitting === target) return;
    const note = submitting = target, submit = form.querySelector('.primary'); submit.disabled = true;
    try {
      await save({text: form.elements.text.value, file: note.file?.id ?? undefined, context: note});
      saved += 1; status.textContent = `${saved} saved · Click anything to comment on the review tool · Esc to finish`;
      if (target === note) composer.close();
    } catch (error) {
      if (target === note) {$('#feedback-composer-shows').textContent = error.message; $('#feedback-composer-shows').hidden = false;}
      else status.textContent = error.message;
    } finally {
      if (submitting === note) submitting = null;
      if (target === note) submit.disabled = false;
    }
  });
  return {start: () => setActive(true)};
}
