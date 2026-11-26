// Pure helpers for the Summary tab: Mermaid sources for its graphs, the module footprint, the hotspots and the findings to show.

// Text in `backticks` renders as code; everything else stays plain text.
export function codeSpans(text) {
  return text.split(/(`[^`]+`)/).filter(Boolean).map(part => part.length > 2 && part.startsWith('`') && part.endsWith('`') ? {code: true, text: part.slice(1, -1)} : {code: false, text: part});
}

// Lines changed per module, largest first; files outside any module share one row.
export function moduleFootprint(files, moduleFor) {
  const rows = new Map();
  for (const file of files) {
    const module = moduleFor(file.path), key = module?.name || '';
    const row = rows.get(key) || {name: key, group: module?.group || '', files: 0, added: 0, deleted: 0};
    row.files++; row.added += file.added || 0; row.deleted += file.deleted || 0;
    rows.set(key, row);
  }
  return [...rows.values()].sort((a, b) => b.added + b.deleted - a.added - a.deleted || b.files - a.files || a.name.localeCompare(b.name));
}

// The changes to read first: highest importance, then the biggest diff.
export function hotspots(files, count = 6) {
  return files.filter(file => !['localization', 'generated', 'snapshot', 'image', 'asset-metadata'].includes(file.kind))
    .sort((a, b) => b.score - a.score || b.added + b.deleted - a.added - a.deleted || a.path.localeCompare(b.path)).slice(0, count);
}

// The module graph drawing: changed dependencies and the nodes they connect, or null when too large to read.
export function moduleGraphDrawing(graph, limit = 32) {
  const ids = Object.keys(graph.nodes || {});
  if (!ids.length || ids.length > limit) return null;
  const nodes = ids.map(id => ({id, label: id, status: graph.nodes[id].status === 'unchanged' ? 'unchanged' : graph.nodes[id].status, kind: 'module', group: graph.nodes[id].group}));
  const edges = [...graph.edges.added.map(([from, to]) => ({from, to, status: 'added'})), ...graph.edges.removed.map(([from, to]) => ({from, to, status: 'removed'}))];
  return {nodes, edges};
}

// Test code and snapshot images leave the Summary unless the person includes test changes.
export const TEST_KINDS = ['test', 'snapshot'];
export function summaryFiles(files, includeTests) {
  return includeTests ? files : files.filter(file => !TEST_KINDS.includes(file.kind));
}

// Unresolved important agent-review findings, oldest first: the few worth seeing before the code.
export function topFindings(comments, count = 3) {
  return comments.filter(comment => comment.author?.kind === 'agent-review' && !comment.resolved && comment.severity === 'important').slice(0, count);
}

// Mermaid label text: quotes and angle brackets become entities, so a label can't close its shape or carry markup.
export function mermaidText(text) {
  return String(text).replace(/[`#"<>]/g, char => ({'`': "'", '#': '#35;', '"': '#quot;', '<': '#lt;', '>': '#gt;'})[char]).replace(/\s+/g, ' ').trim();
}

const SHAPES = {view: ['(["', '"])'], protocol: ['{{"', '"}}'], data: ['[("', '")]'], external: ['>"', '"]'], service: ['[["', '"]]']};
const STATUS_STYLES = {
  added: 'fill:#173323,stroke:#4f9e6e,color:#e1e1e5',
  changed: 'fill:#332b12,stroke:#c9a227,color:#e1e1e5',
  removed: 'fill:#3a1b20,stroke:#b5545f,color:#e1e1e5,stroke-dasharray:4 3',
  unchanged: 'fill:#26262b,stroke:#5b5b63,color:#e1e1e5',
};
const EDGE_STYLES = {added: 'stroke:#4f9e6e,stroke-width:1.8px', removed: 'stroke:#b5545f,stroke-width:1.6px'};

// A status-colored flowchart of nodes and edges. Node ids become n0, n1… so any id is safe; `ids` maps them back.
export function graphMermaid(nodes, edges, direction = 'TD') {
  const ids = new Map(nodes.map((node, index) => [node.id, `n${index}`])), lines = [`flowchart ${direction}`];
  for (const node of nodes) {
    const [open, close] = SHAPES[node.kind] || ['["', '"]'];
    const label = mermaidText(node.label) + (node.note ? `<br/><small>${mermaidText(node.note)}</small>` : '');
    lines.push(`  ${ids.get(node.id)}${open}${label}${close}:::${node.status || 'unchanged'}`);
  }
  const drawn = edges.filter(edge => ids.has(edge.from) && ids.has(edge.to));
  for (const edge of drawn) {
    const arrow = edge.status === 'removed' ? '-.->' : '-->';
    lines.push(`  ${ids.get(edge.from)} ${arrow}${edge.label ? `|"${mermaidText(edge.label)}"|` : ''} ${ids.get(edge.to)}`);
  }
  for (const [status, style] of Object.entries(STATUS_STYLES)) lines.push(`  classDef ${status} ${style}`);
  drawn.forEach((edge, index) => {if (EDGE_STYLES[edge.status]) lines.push(`  linkStyle ${index} ${EDGE_STYLES[edge.status]}`);});
  return {source: lines.join('\n'), ids: new Map([...ids].map(([id, key]) => [key, nodes.find(node => node.id === id)]))};
}
