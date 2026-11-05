// Pure helpers for the Summary tab: a layered graph layout, the module footprint and the hotspots.

// Text in `backticks` renders as code; everything else stays plain text.
export function codeSpans(text) {
  return text.split(/(`[^`]+`)/).filter(Boolean).map(part => part.length > 2 && part.startsWith('`') && part.endsWith('`') ? {code: true, text: part.slice(1, -1)} : {code: false, text: part});
}

export const NODE_HEIGHT = 30, NOTE_HEIGHT = 44;

export function nodeWidth(node) {
  return Math.round(Math.max(64, 7.4 * node.label.length + 26 + (node.tag ? 16 : 0), node.note ? 6.2 * node.note.length + 22 : 0));
}

// Layers follow the longest path from the sources, so dependencies sit below their dependents.
// Cycles are broken at their DFS back edges, which then point upwards.
function layers(ids, edges) {
  const out = new Map(ids.map(id => [id, []])), state = new Map(), back = new Set();
  for (const edge of edges) out.get(edge.from).push(edge);
  const visit = id => {
    state.set(id, 1);
    for (const edge of out.get(id)) {
      if (state.get(edge.to) === 1) back.add(edge);
      else if (!state.has(edge.to)) visit(edge.to);
    }
    state.set(id, 2);
  };
  for (const id of ids) if (!state.has(id)) visit(id);
  const forward = edges.filter(edge => !back.has(edge)), indegree = new Map(ids.map(id => [id, 0])), layer = new Map(ids.map(id => [id, 0]));
  for (const edge of forward) indegree.set(edge.to, indegree.get(edge.to) + 1);
  const queue = ids.filter(id => !indegree.get(id));
  while (queue.length) {
    const id = queue.shift();
    for (const edge of forward.filter(edge => edge.from === id)) {
      layer.set(edge.to, Math.max(layer.get(edge.to), layer.get(id) + 1));
      indegree.set(edge.to, indegree.get(edge.to) - 1);
      if (!indegree.get(edge.to)) queue.push(edge.to);
    }
  }
  return layer;
}

// Barycenter sweeps order each layer by its neighbors' positions to cut crossings; wide layers wrap into rows.
export function layoutGraph(nodes, edges, {maxWidth = 1100, gapX = 18, gapY = 54} = {}) {
  const ids = nodes.map(node => node.id), known = new Set(ids);
  const links = edges.filter(edge => known.has(edge.from) && known.has(edge.to) && edge.from !== edge.to);
  const layer = layers(ids, links), depth = Math.max(0, ...layer.values());
  const rows = Array.from({length: depth + 1}, () => []);
  for (const id of ids) rows[layer.get(id)].push(id);
  const position = new Map();
  const index = () => {for (const row of rows) row.forEach((id, i) => position.set(id, i / Math.max(1, row.length - 1)));};
  index();
  const neighbors = new Map(ids.map(id => [id, []]));
  for (const edge of links) {neighbors.get(edge.from).push(edge.to); neighbors.get(edge.to).push(edge.from);}
  for (let sweep = 0; sweep < 6; sweep++) {
    const order = sweep % 2 ? [...rows.keys()].reverse() : [...rows.keys()];
    for (const r of order) {
      const center = id => {const around = neighbors.get(id).filter(other => layer.get(other) !== r); return around.length ? around.reduce((sum, other) => sum + position.get(other), 0) / around.length : position.get(id);};
      const centers = new Map(rows[r].map(id => [id, center(id)]));
      rows[r].sort((a, b) => centers.get(a) - centers.get(b) || ids.indexOf(a) - ids.indexOf(b));
      rows[r].forEach((id, i) => position.set(id, i / Math.max(1, rows[r].length - 1)));
    }
  }
  const byId = new Map(nodes.map(node => [node.id, node])), placed = new Map(), lines = [];
  for (const row of rows) {
    let line = [], width = 0;
    for (const id of row) {
      const w = nodeWidth(byId.get(id));
      if (line.length && width + gapX + w > maxWidth) {lines.push(line); line = []; width = 0;}
      width += (line.length ? gapX : 0) + w; line.push({id, w});
    }
    if (line.length) lines.push(line);
  }
  const widths = lines.map(line => line.reduce((sum, item) => sum + item.w, 0) + gapX * (line.length - 1)), width = Math.max(0, ...widths);
  let y = 0;
  lines.forEach((line, i) => {
    const h = Math.max(...line.map(item => byId.get(item.id).note ? NOTE_HEIGHT : NODE_HEIGHT));
    let x = (width - widths[i]) / 2;
    for (const item of line) {placed.set(item.id, {...byId.get(item.id), x, y: y + (h - (byId.get(item.id).note ? NOTE_HEIGHT : NODE_HEIGHT)) / 2, w: item.w, h: byId.get(item.id).note ? NOTE_HEIGHT : NODE_HEIGHT, row: i}); x += item.w + gapX;}
    y += h + gapY;
  });
  const routed = links.map(edge => {
    const a = placed.get(edge.from), b = placed.get(edge.to), down = b.row > a.row;
    const start = {x: a.x + a.w / 2, y: down ? a.y + a.h : a.y}, end = {x: b.x + b.w / 2, y: down ? b.y : b.y + b.h};
    if (a.row === b.row) {start.y = a.y + a.h; end.y = b.y + b.h;}
    const bend = a.row === b.row ? gapY * 0.6 : Math.max(18, Math.abs(end.y - start.y) / 2);
    const c1 = down || a.row === b.row ? start.y + bend : start.y - bend, c2 = down ? end.y - bend : end.y + bend;
    return {...edge, path: `M${start.x},${start.y} C${start.x},${c1} ${end.x},${c2} ${end.x},${end.y}`, label: edge.label, mid: {x: (start.x + end.x) / 2, y: (start.y + end.y) / 2}};
  });
  return {nodes: [...placed.values()], edges: routed, width, height: Math.max(0, y - gapY)};
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
  return files.filter(file => !['localization', 'generated', 'snapshot'].includes(file.kind))
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
