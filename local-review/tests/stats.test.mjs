import test from 'node:test';
import assert from 'node:assert/strict';
import {diffStats, fileType, signed} from '../stats.mjs';

const files = [
  {path: 'Sources/Account.swift', status: 'M', kind: 'code', added: 10, deleted: 4},
  {path: 'Sources/AccountView.swift', status: 'A', kind: 'view', added: 30, deleted: 0},
  {path: 'Tests/AccountTests.swift', status: '?', kind: 'test', added: 5, deleted: 0},
  {path: 'Sources/Old.swift', status: 'D', kind: 'code', added: 0, deleted: 12},
  {path: 'Tests/__Snapshots__/account.png', status: 'M', kind: 'snapshot', added: 0, deleted: 0, binary: true, image: true},
  {path: 'Makefile', status: 'M', kind: 'code', added: 1, deleted: 1},
];

test('totals count lines and file statuses across the scope', () => {
  const stats = diffStats(files);
  assert.deepEqual([stats.files, stats.created, stats.modified, stats.removed], [6, 2, 3, 1]);
  assert.deepEqual([stats.added, stats.deleted, stats.uncounted], [46, 17, 1]);
});

test('kinds and file types sort by changed lines, then file count', () => {
  const stats = diffStats(files);
  assert.deepEqual(stats.byKind.map(row => [row.label, row.files, row.added, row.deleted]), [
    ['Views and navigation', 1, 30, 0], ['Code', 3, 11, 17], ['Unit tests', 1, 5, 0], ['Snapshots', 1, 0, 0],
  ]);
  assert.deepEqual(stats.byType.map(row => [row.label, row.files]), [['.swift', 4], ['No extension', 1], ['.png', 1]]);
  assert.deepEqual(diffStats([]), {files: 0, created: 0, removed: 0, modified: 0, added: 0, deleted: 0, uncounted: 0, byKind: [], byType: []});
});

test('file types use the lowercase extension and dotfiles have none', () => {
  assert.equal(fileType('Docs/README.MD'), '.md');
  assert.equal(fileType('.gitignore'), 'No extension');
  assert.equal(fileType('Sources/user.pb.swift'), '.swift');
  assert.deepEqual([signed(1200), signed(-3), signed(0)], ['+1,200', '−3', '0']);
});
