import test from 'node:test';
import assert from 'node:assert/strict';
import {codeSpans, layoutGraph, moduleFootprint, hotspots, moduleGraphDrawing, nodeWidth} from '../summary.mjs';

const node = (id, extra = {}) => ({id, label: id, ...extra});

test('backticks mark code spans and unmatched ones stay text', () => {
  assert.deepEqual(codeSpans('Calls `OrderService` once'), [{code: false, text: 'Calls '}, {code: true, text: 'OrderService'}, {code: false, text: ' once'}]);
  assert.deepEqual(codeSpans('A `lone tick'), [{code: false, text: 'A `lone tick'}]);
});

test('dependencies sit below their dependents and edges run top to bottom', () => {
  const layout = layoutGraph([node('View'), node('Interactor'), node('Service'), node('Store')],
    [{from: 'View', to: 'Interactor'}, {from: 'Interactor', to: 'Service'}, {from: 'Interactor', to: 'Store'}, {from: 'View', to: 'Missing'}]);
  const y = Object.fromEntries(layout.nodes.map(n => [n.id, n.y]));
  assert.ok(y.View < y.Interactor && y.Interactor < y.Service);
  assert.equal(y.Service, y.Store);
  assert.equal(layout.edges.length, 3, 'Edges to unknown nodes are dropped');
  for (const n of layout.nodes) assert.ok(n.x >= 0 && n.x + n.w <= layout.width + 0.001);
});

test('cycles still lay out, with the back edge pointing up', () => {
  const layout = layoutGraph([node('A'), node('B')], [{from: 'A', to: 'B'}, {from: 'B', to: 'A'}]);
  const [a, b] = ['A', 'B'].map(id => layout.nodes.find(n => n.id === id));
  assert.ok(a.y < b.y);
  assert.match(layout.edges[1].path, new RegExp(`^M${b.x + b.w / 2},${b.y} `), 'The back edge leaves from the top of its source');
});

test('barycenter ordering uncrosses edges and wide layers wrap', () => {
  const layout = layoutGraph([node('P1'), node('P2'), node('C2'), node('C1')], [{from: 'P1', to: 'C1'}, {from: 'P2', to: 'C2'}]);
  const x = Object.fromEntries(layout.nodes.map(n => [n.id, n.x]));
  assert.ok((x.P1 < x.P2) === (x.C1 < x.C2));
  const wide = layoutGraph(Array.from({length: 12}, (_, i) => node(`TargetNumber${i}`)), [], {maxWidth: 500});
  assert.ok(wide.width <= 500 && new Set(wide.nodes.map(n => n.y)).size > 1);
  assert.ok(nodeWidth(node('A', {note: 'a much longer explanation'})) > nodeWidth(node('A')));
  assert.equal(nodeWidth(node('OrderService', {tag: 'P'})) - nodeWidth(node('OrderService')), 16);
});

test('module footprint and hotspots rank what to read first', () => {
  const files = [
    {path: 'Modules/Home/A.swift', kind: 'code', score: 40, added: 10, deleted: 2},
    {path: 'Modules/Home/B.swift', kind: 'view', score: 90, added: 1, deleted: 0},
    {path: 'Modules/Login/C.swift', kind: 'code', score: 90, added: 30, deleted: 0},
    {path: 'Resources/en.strings', kind: 'localization', score: 99, added: 5, deleted: 5},
  ];
  const moduleFor = path => path.startsWith('Modules/') ? {name: path.split('/')[1], group: 'Modules'} : null;
  assert.deepEqual(moduleFootprint(files, moduleFor).map(r => [r.name, r.files, r.added, r.deleted]), [['Login', 1, 30, 0], ['Home', 2, 11, 2], ['', 1, 5, 5]]);
  assert.deepEqual(hotspots(files, 2).map(f => f.path), ['Modules/Login/C.swift', 'Modules/Home/B.swift']);
});

test('module graph drawings show changed dependencies and give up when too large', () => {
  const graph = {nodes: {A: {status: 'unchanged', group: 'G'}, B: {status: 'added', group: 'G'}, C: {status: 'removed', group: 'G'}},
                 edges: {added: [['A', 'B']], removed: [['A', 'C']]}};
  const drawing = moduleGraphDrawing(graph);
  assert.deepEqual(drawing.nodes.map(n => [n.id, n.status]), [['A', 'unchanged'], ['B', 'added'], ['C', 'removed']]);
  assert.deepEqual(drawing.edges, [{from: 'A', to: 'B', status: 'added'}, {from: 'A', to: 'C', status: 'removed'}]);
  assert.equal(moduleGraphDrawing(graph, 2), null);
  assert.equal(moduleGraphDrawing({nodes: {}, edges: {added: [], removed: []}}), null);
});
