// Unchanged lines between hunks align one-to-one on both sides, so hidden context can be
// restored from the full file text without recomputing the diff.
export const CONTEXT_STEP = 20;
const HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

// A gap is keyed by the hunk row index it precedes, or 'end' for lines after the last hunk.
export function contextGaps(rows, oldCount, newCount) {
  const gaps = [];
  let nextOld = 1, nextNew = 1, sawHunk = false;
  rows.forEach((row, index) => {
    if (row.type === 'hunk') {
      const match = row.text.match(HEADER);
      if (!match) return;
      // A zero-length side names the line before the hunk.
      const oldStart = Number(match[1]) + (match[2] === '0' ? 1 : 0), newStart = Number(match[3]) + (match[4] === '0' ? 1 : 0);
      const length = Math.min(oldStart - nextOld, newStart - nextNew);
      if (length > 0) gaps.push({key: index, oldStart: nextOld, newStart: nextNew, length, first: !sawHunk, last: false});
      sawHunk = true;
      return;
    }
    if (row.old != null) nextOld = row.old + 1;
    if (row.new != null) nextNew = row.new + 1;
  });
  const length = Math.min(oldCount - nextOld + 1, newCount - nextNew + 1);
  if (sawHunk && length > 0) gaps.push({key: 'end', oldStart: nextOld, newStart: nextNew, length, first: false, last: true});
  return gaps;
}

// `before` counts lines revealed below the previous hunk; `after` counts lines revealed above the next one.
export function expandGap(expansion = {before: 0, after: 0}, gap, direction, step = CONTEXT_STEP) {
  const {before = 0, after = 0} = expansion;
  if (direction === 'all') return {before: gap.length, after: 0};
  const hidden = Math.max(0, gap.length - before - after), amount = Math.min(step, hidden);
  return direction === 'before' ? {before: before + amount, after} : {before, after: after + amount};
}

export function expandAll(gaps) {
  return new Map(gaps.map(gap => [gap.key, expandGap(undefined, gap, 'all')]));
}

export function fullyExpanded(gaps, expansions) {
  return gaps.every(gap => {const {before = 0, after = 0} = expansions?.get(gap.key) || {}; return before + after >= gap.length;});
}

// Gap rows stay `hunk` rows so highlighting restarts and split layout treats them as separators.
export function withContext(rows, gaps, lines, expansions = new Map()) {
  const byKey = new Map(gaps.map(gap => [gap.key, gap])), result = [];
  const fill = (gap, text) => {
    const expansion = lines ? expansions.get(gap.key) || {} : {};
    const before = Math.min(expansion.before || 0, gap.length), after = Math.min(expansion.after || 0, gap.length - before);
    const context = offset => ({type: 'context', text: lines.new[gap.newStart - 1 + offset] ?? lines.old[gap.oldStart - 1 + offset] ?? '', old: gap.oldStart + offset, new: gap.newStart + offset, expanded: true});
    for (let offset = 0; offset < before; offset++) result.push(context(offset));
    const hidden = gap.length - before - after;
    if (hidden > 0) result.push({type: 'hunk', text, old: null, new: null, gap: gap.key, hidden, first: gap.first, last: gap.last});
    for (let offset = gap.length - after; offset < gap.length; offset++) result.push(context(offset));
  };
  rows.forEach((row, index) => {
    if (row.type === 'hunk' && byKey.has(index)) fill(byKey.get(index), row.text);
    else result.push(row);
  });
  if (byKey.has('end')) fill(byKey.get('end'), '');
  return result;
}
