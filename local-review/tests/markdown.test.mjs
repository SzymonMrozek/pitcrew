import test from 'node:test';
import assert from 'node:assert/strict';
import {renderMarkdown, isMarkdown} from '../markdown.mjs';

test('Markdown previews render headings, nested lists, tables, tasks and fenced code', () => {
  const html = renderMarkdown('# Contract\n\n- Parent\n  - Child\n- [x] Done\n\n| Field | Type |\n| --- | --- |\n| name | string |\n\n```swift\nlet value = "<script>"\n```\n\n**Bold** and *italic*');
  for (const fragment of ['<h1>Contract</h1>', '<ul>', '<table>', '<strong>Bold</strong>', '<em>italic</em>', 'type="checkbox"', '&lt;script&gt;']) assert.ok(html.includes(fragment), fragment);
  assert.equal(isMarkdown('docs/API.MD'), true);
  assert.equal(isMarkdown('docs/API.markdown'), true);
  assert.equal(isMarkdown('Code.swift'), false);
});

test('Markdown content cannot run HTML or unsafe links, or load remote images', () => {
  const html = renderMarkdown('<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[bad](javascript:alert%281%29) [entity](jav&#x61;script:alert%281%29) [data](data:text/html,attack) [local](../file.md)\n\n![logo](https://example.com/tracker.png)\n\n[good](https://example.com "title")\n\n`<iframe>`');
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(html.includes('&lt;img'));
  assert.ok(html.includes('href="https://example.com"'));
  assert.ok(html.includes('rel="noopener noreferrer"'));
  assert.ok(html.includes('[Image: logo]'));
  for (const unsafe of ['<script', '<img', '<iframe', 'href="javascript:', 'href="jav&#', 'href="data:', 'tracker.png', 'href="../']) assert.equal(html.includes(unsafe), false, unsafe);
});
