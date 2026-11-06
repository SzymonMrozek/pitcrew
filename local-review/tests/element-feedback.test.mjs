import test from 'node:test';
import assert from 'node:assert/strict';
import {composerPosition, elementContext, feedbackWhere, isCommentShortcut, selectorPath} from '../element-feedback.mjs';

class Node {
  constructor(tag, {id = '', classes = [], text = '', attrs = {}, data = {}, html, children = []} = {}) {
    Object.assign(this, {tagName: tag.toUpperCase(), id, classList: classes, innerText: text, attrs, dataset: data, title: attrs.title ?? '', outerHTML: html ?? `<${tag}>${text}</${tag}>`, children, parentElement: null});
    children.forEach(child => {child.parentElement = this;});
  }
  matches(selector) {return selector === this.tagName.toLowerCase() || selector === '#' + this.id || this.classList.some(name => selector === '.' + name);}
  getAttribute(name) {return this.attrs[name] ?? null;}
  matchesAny(selectors) {
    return selectors.split(', ').some(selector => selector.startsWith('[data-') ? this.dataset[selector.slice(6, -1)] !== undefined : this.matches(selector));
  }
  closest(selectors) {
    for (let node = this; node; node = node.parentElement) if (node.matchesAny(selectors)) return node;
    return null;
  }
  querySelector(selectors) {for (const child of this.children) {const found = child.matchesAny(selectors) ? child : child.querySelector(selectors); if (found) return found;} return null;}
  getBoundingClientRect() {return {left: 10, top: 20, width: 100, height: 30};}
}
const view = {tabLabel: 'Changes', tab: 'all'};
const pin = {x: 15.4, y: 25.6};

test('a diff line names its file, side, line and code', () => {
  const number = new Node('button', {classes: ['line-number'], text: '42', data: {side: 'new', line: '42'}});
  const token = new Node('span', {classes: ['tok-keyword'], text: 'let'});
  const code = new Node('code', {text: 'let value = 1', children: [token]});
  const cell = new Node('div', {classes: ['code-cell', 'add'], children: [number, code]});
  const row = new Node('div', {classes: ['diff-row'], children: [cell]});
  new Node('main', {id: 'content', children: [new Node('section', {classes: ['review-file'], data: {file: 'abc', path: 'Sources/App.swift'}, children: [row]})]});
  const context = elementContext(token, pin, view, '');
  assert.deepEqual(context.componentPath, ['Changed file', 'Diff row']);
  assert.equal(context.component, 'Diff row');
  assert.deepEqual(context.file, {id: 'abc', path: 'Sources/App.swift', side: 'new', line: 42, code: 'let value = 1'});
  assert.equal(context.text, 'let');
  assert.equal(feedbackWhere(context), 'Changes › Changed file › Diff row');
});

test('dialogs use their heading', () => {
  const heading = new Node('h2'); heading.textContent = 'Run the app';
  const button = new Node('button', {id: 'run-reload', text: 'Refresh list'});
  new Node('dialog', {id: 'run-dialog', children: [heading, button]});
  const context = elementContext(button, pin, view, '');
  assert.equal(context.dialog, 'Run the app');
  assert.equal(context.component, 'Button "Refresh list"');
  assert.equal(feedbackWhere(context), 'Changes › Run the app › Button "Refresh list"');
});

test('an unnamed element still records where it is', () => {
  const span = new Node('span', {classes: ['muted', 'selected'], text: '  Some   status  '});
  new Node('html', {children: [new Node('body', {children: [new Node('div', {id: 'iteration-context', children: [new Node('p', {children: [span]})]})]})]});
  const orphan = new Node('span', {id: 'lonely', text: 'x'});
  new Node('div', {classes: ['nowhere'], children: [orphan]});
  assert.equal(selectorPath(span), 'div#iteration-context > p > span.muted');
  assert.equal(elementContext(span, pin, view, '').text, 'Some status');
  assert.equal(elementContext(orphan, pin, view, '').component, 'span#lonely');
  assert.deepEqual(elementContext(orphan, pin, view, '').pin, {x: 15, y: 26, inComponent: {x: 5, y: 6}});
});

test('source viewer lines name their full path and number', () => {
  const code = new Node('code', {text: 'func run()'});
  const row = new Node('div', {classes: ['source-line'], children: [new Node('span', {classes: ['source-number'], text: '7'}), code]});
  row.children[0].textContent = '7';
  new Node('div', {id: 'source-body', data: {path: 'Sources/Runner.swift'}, children: [row]});
  assert.deepEqual(elementContext(code, pin, view, '').file, {id: null, path: 'Sources/Runner.swift', side: null, line: 7, code: 'func run()'});
});

test('the token is removed before anything is cut, so no prefix of it survives', () => {
  const token = 'secrettoken';
  const html = '<a>' + 'y'.repeat(1990) + `href="#${token}"`;
  const name = 'x'.repeat(75) + token;
  const context = elementContext(new Node('a', {text: name, html}), pin, view, token);
  assert.ok(!JSON.stringify(context).includes('secret'));
});

test('the review token never reaches saved markup or text', () => {
  const link = new Node('a', {text: 'Open secrettoken', html: '<a href="/queue.html#secrettoken">Open</a>'});
  const context = elementContext(link, pin, view, 'secrettoken');
  assert.ok(!JSON.stringify(context).includes('secrettoken'));
  assert.match(context.html, /\[token\]/);
});

test('long text and markup are bounded', () => {
  const panel = new Node('section', {classes: ['summary'], text: 'x'.repeat(5000), html: 'y'.repeat(5000)});
  const context = elementContext(panel, pin, view, '');
  assert.equal(context.text.length, 400);
  assert.equal(context.componentText.length, 1000);
  assert.equal(context.html.length, 2000);
});

test('a form control keeps its live value', () => {
  const field = new Node('input', {attrs: {'aria-label': 'Search'}});
  Object.assign(field, {value: 'query', checked: false});
  assert.deepEqual(elementContext(field, pin, view, '').element, {tag: 'input', id: null, classes: [], role: null, name: 'Search', value: 'query', checked: false});
});

test('the shortcut is Cmd or Ctrl with Shift and C only', () => {
  assert.ok(isCommentShortcut({metaKey: true, shiftKey: true, key: 'C'}));
  assert.ok(isCommentShortcut({ctrlKey: true, shiftKey: true, key: 'c'}));
  assert.ok(!isCommentShortcut({metaKey: true, key: 'c'}));
  assert.ok(!isCommentShortcut({shiftKey: true, key: 'C'}));
  assert.ok(!isCommentShortcut({metaKey: true, shiftKey: true, altKey: true, key: 'c'}));
});

test('the composer stays on screen', () => {
  const size = {width: 340, height: 200}, viewport = {width: 1000, height: 700};
  assert.deepEqual(composerPosition({x: 100, y: 100}, size, viewport), {left: 116, top: 76});
  assert.equal(composerPosition({x: 900, y: 100}, size, viewport).left, 544);
  assert.equal(composerPosition({x: 100, y: 690}, size, viewport).top, 484);
  assert.deepEqual(composerPosition({x: 5, y: 5}, {width: 340, height: 200}, {width: 300, height: 150}), {left: 16, top: 16});
});
