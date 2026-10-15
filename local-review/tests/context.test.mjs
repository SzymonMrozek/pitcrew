import test from 'node:test';
import assert from 'node:assert/strict';
import {contextGaps, expandGap, expandAll, fullyExpanded, withContext} from '../context.mjs';

const lines = Array.from({length: 40}, (_, index) => `line ${index + 1}`);
const context = (old, next = old) => ({type: 'context', text: `line ${next}`, old, new: next});
// One change at line 10 and one at line 30, with difflib's four lines of context.
const rows = [
  {type: 'hunk', text: '@@ -6,9 +6,9 @@', old: null, new: null},
  ...[6, 7, 8, 9].map(n => context(n)), {type: 'delete', text: 'old 10', old: 10, new: null}, {type: 'add', text: 'line 10', old: null, new: 10}, ...[11, 12, 13, 14].map(n => context(n)),
  {type: 'hunk', text: '@@ -26,9 +26,9 @@', old: null, new: null},
  ...[26, 27, 28, 29].map(n => context(n)), {type: 'delete', text: 'old 30', old: 30, new: null}, {type: 'add', text: 'line 30', old: null, new: 30}, ...[31, 32, 33, 34].map(n => context(n)),
];

test('gaps cover the unchanged lines before, between and after hunks', () => {
  assert.deepEqual(contextGaps(rows, 40, 40), [
    {key: 0, oldStart: 1, newStart: 1, length: 5, first: true, last: false},
    {key: 11, oldStart: 15, newStart: 15, length: 11, first: false, last: false},
    {key: 'end', oldStart: 35, newStart: 35, length: 6, first: false, last: true},
  ]);
  assert.deepEqual(contextGaps([{type: 'hunk', text: '@@ -0,0 +1,2 @@'}, {type: 'add', text: 'a', old: null, new: 1}, {type: 'add', text: 'b', old: null, new: 2}], 0, 2), []);
  assert.deepEqual(contextGaps([{type: 'hunk', text: 'End-of-file newline or line endings changed'}], 3, 3), []);
});

test('expanding reveals context from either edge and removes closed gaps', () => {
  const gaps = contextGaps(rows, 40, 40), source = {old: lines, new: lines};
  const collapsed = withContext(rows, gaps, source);
  assert.equal(collapsed.filter(row => row.gap !== undefined).length, 3);
  assert.equal(collapsed.find(row => row.gap === 'end').hidden, 6);
  const middle = gaps[1];
  let expansion = expandGap(undefined, middle, 'before', 4);
  expansion = expandGap(expansion, middle, 'after', 3);
  assert.deepEqual(expansion, {before: 4, after: 3});
  const partial = withContext(rows, gaps, source, new Map([[11, expansion]]));
  const gapIndex = partial.findIndex(row => row.gap === 11);
  assert.deepEqual(partial.slice(gapIndex - 4, gapIndex).map(row => row.new), [15, 16, 17, 18]);
  assert.equal(partial[gapIndex].hidden, 4);
  assert.deepEqual(partial.slice(gapIndex + 1, gapIndex + 4).map(row => [row.old, row.new, row.text]), [[23, 23, 'line 23'], [24, 24, 'line 24'], [25, 25, 'line 25']]);
  assert.deepEqual(expandGap({before: 4, after: 3}, middle, 'after', 20), {before: 4, after: 7});
  const full = withContext(rows, gaps, source, expandAll(gaps));
  assert.equal(full.some(row => row.type === 'hunk'), false);
  assert.deepEqual(full.filter(row => row.new != null).map(row => row.new), Array.from({length: 40}, (_, index) => index + 1));
  assert.equal(fullyExpanded(gaps, expandAll(gaps)), true);
  assert.equal(fullyExpanded(gaps, new Map([[11, expansion]])), false);
});

test('gaps stay collapsed until the file text is available', () => {
  const gaps = contextGaps(rows, 40, 40);
  assert.deepEqual(withContext(rows, gaps, null, expandAll(gaps)).filter(row => row.gap !== undefined).map(row => row.hidden), [5, 11, 6]);
});

test('context lines map old and new numbers when a hunk shifted the file', () => {
  const shifted = [{type: 'hunk', text: '@@ -1,4 +1,6 @@'}, {type: 'add', text: 'a', old: null, new: 1}, {type: 'add', text: 'b', old: null, new: 2}, ...[1, 2, 3, 4].map(n => context(n, n + 2))];
  const gaps = contextGaps(shifted, 10, 12);
  assert.deepEqual(gaps, [{key: 'end', oldStart: 5, newStart: 7, length: 6, first: false, last: true}]);
  const result = withContext(shifted, gaps, {old: lines.slice(0, 10), new: ['a', 'b', ...lines.slice(0, 10)]}, expandAll(gaps));
  assert.deepEqual(result.at(-1), {type: 'context', text: 'line 10', old: 10, new: 12, expanded: true});
});
