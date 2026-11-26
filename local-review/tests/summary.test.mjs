import test from 'node:test';
import assert from 'node:assert/strict';
import {codeSpans, moduleFootprint, hotspots, moduleGraphDrawing, graphMermaid, mermaidText, summaryFiles, topFindings} from '../summary.mjs';

const node = (id, extra = {}) => ({id, label: id, ...extra});

test('backticks mark code spans and unmatched ones stay text', () => {
  assert.deepEqual(codeSpans('Calls `OrderService` once'), [{code: false, text: 'Calls '}, {code: true, text: 'OrderService'}, {code: false, text: ' once'}]);
  assert.deepEqual(codeSpans('A `lone tick'), [{code: false, text: 'A `lone tick'}]);
});

test('graphs become Mermaid flowcharts with safe ids, status classes and file links', () => {
  const {source, ids} = graphMermaid([node('Order View', {kind: 'view', status: 'added', file: 'Sources/OrderView.swift'}),
    node('Service<T>', {kind: 'protocol', note: 'Retries "once"'}), node('Store', {kind: 'data', status: 'removed'})],
    [{from: 'Order View', to: 'Service<T>', label: 'calls', status: 'added'}, {from: 'Service<T>', to: 'Store', status: 'removed'}, {from: 'Store', to: 'Missing'}]);
  const lines = source.split('\n');
  assert.equal(lines[0], 'flowchart TD');
  assert.ok(lines.includes('  n0(["Order View"]):::added'));
  assert.ok(lines.includes('  n1{{"Service#lt;T#gt;<br/><small>Retries #quot;once#quot;</small>"}}:::unchanged'));
  assert.ok(lines.includes('  n2[("Store")]:::removed'));
  assert.ok(lines.includes('  n0 -->|"calls"| n1') && lines.includes('  n1 -.-> n2'));
  assert.equal(lines.filter(line => line.includes('Missing')).length, 0, 'Edges to unknown nodes are dropped');
  assert.ok(lines.includes('  linkStyle 0 stroke:#4f9e6e,stroke-width:1.8px') && lines.includes('  linkStyle 1 stroke:#b5545f,stroke-width:1.6px'));
  assert.equal(ids.get('n0').file, 'Sources/OrderView.swift');
  assert.equal(mermaidText('`a` #1\n  "b"'), "'a' #35;1 #quot;b#quot;");
});

test('test changes leave the Summary unless included, and only unresolved important findings surface', () => {
  const files = [{path: 'A.swift', kind: 'code'}, {path: 'ATests.swift', kind: 'test'}, {path: '__Snapshots__/a.png', kind: 'snapshot'}];
  assert.deepEqual(summaryFiles(files, false).map(f => f.path), ['A.swift']);
  assert.equal(summaryFiles(files, true).length, 3);
  const finding = (id, extra) => ({id, author: {kind: 'agent-review'}, severity: 'important', resolved: false, ...extra});
  const comments = [finding('a'), finding('b', {resolved: true}), finding('c', {severity: 'nit'}), {id: 'd', author: {kind: 'person'}, resolved: false},
                    finding('e'), finding('f'), finding('g')];
  assert.deepEqual(topFindings(comments).map(c => c.id), ['a', 'e', 'f']);
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
  const assets = [
    {path: 'Hero.imageset/Hero.png', kind: 'image', score: 40, added: 0, deleted: 0},
    {path: 'Hero.imageset/Contents.json', kind: 'asset-metadata', score: 10, added: 5, deleted: 0},
  ];
  assert.deepEqual(hotspots([...files, ...assets]).map(f => f.path), ['Modules/Login/C.swift', 'Modules/Home/B.swift', 'Modules/Home/A.swift']);
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
