export function pixelDiff(oldPixels, newPixels) {
  const result = new Uint8ClampedArray(oldPixels.length);
  let changed = 0;
  for (let i = 0; i < oldPixels.length; i += 4) {
    const different = oldPixels[i] !== newPixels[i] || oldPixels[i + 1] !== newPixels[i + 1] || oldPixels[i + 2] !== newPixels[i + 2] || oldPixels[i + 3] !== newPixels[i + 3];
    if (different) {
      result.set([239, 58, 111, 255], i);
      changed++;
    } else {
      const gray = Math.round((newPixels[i] + newPixels[i + 1] + newPixels[i + 2]) / 3);
      result.set([gray, gray, gray, Math.round(newPixels[i + 3] * 0.25)], i);
    }
  }
  return {pixels: result, changed};
}

export function splitRows(rows) {
  const result = [];
  for (let i = 0; i < rows.length;) {
    if (rows[i].type === 'delete' || rows[i].type === 'add') {
      const removed = [], added = [];
      while (i < rows.length && ['delete', 'add'].includes(rows[i].type)) {
        (rows[i].type === 'delete' ? removed : added).push(rows[i++]);
      }
      for (let j = 0; j < Math.max(removed.length, added.length); j++) result.push({left: removed[j], right: added[j]});
    } else {
      result.push({left: rows[i], right: rows[i++]});
    }
  }
  return result;
}

// Globs are intentionally literal except * and ?; no user-provided regular expressions.
export function globMatch(pattern, path) {
  const expression = pattern.split('').map(c => c === '*' ? '.*' : c === '?' ? '.' : /[\\^$+.[\]{}()|]/.test(c) ? '\\' + c : c).join('');
  return new RegExp('^' + expression + '$').test(path);
}
