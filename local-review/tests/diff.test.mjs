import test from 'node:test';
import assert from 'node:assert/strict';
import {pixelDiff, splitRows, globMatch} from '../diff.mjs';
test('pixel diff includes RGB, alpha, and transparent canvas padding', () => {
  const old = new Uint8ClampedArray([0,0,0,255, 255,0,0,255, 0,0,0,0]);
  const next = new Uint8ClampedArray([0,0,0,255, 0,0,0,255, 0,0,0,255]);
  const result = pixelDiff(old, next);
  assert.equal(result.changed, 2);
  assert.deepEqual([...result.pixels.slice(4,8)], [239,58,111,255]);
  assert.equal(result.pixels[3], 64);
});
test('split diff pairs replacements and preserves line identities', () => {
  const rows = [{type:'hunk'}, {type:'delete', old:2}, {type:'add', new:2}, {type:'add', new:3}, {type:'context', old:3, new:4}];
  const pairs = splitRows(rows);
  assert.equal(pairs.length, 4);
  assert.equal(pairs[1].left.old, 2);
  assert.equal(pairs[1].right.new, 2);
  assert.equal(pairs[2].left, undefined);
  assert.equal(pairs[3].right.new, 4);
});
test('exclusion globs escape regex syntax and cross path separators', () => {
  assert.ok(globMatch('*/Generated/*', 'Modules/A/Generated/Strings.swift'));
  assert.ok(globMatch('a?.swift', 'ab.swift'));
  assert.ok(globMatch('a[1].swift', 'a[1].swift'));
  assert.equal(globMatch('a[1].swift', 'a1.swift'), false);
  assert.equal(globMatch('*.tests.swift', 'test.png'), false);
});
