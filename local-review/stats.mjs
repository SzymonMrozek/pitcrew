// Line counts for the files in the selected review scope, grouped by review kind and by file type.
export const KIND_LABELS = {
  code: 'Code', view: 'Views and navigation', test: 'Unit tests', snapshot: 'Snapshots',
  localization: 'Localization', manifest: 'Project manifests', generated: 'Generated code',
};

export function fileType(path) {
  const name = path.split('/').pop(), dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot).toLowerCase() : 'No extension';
}

function group(files, key, label) {
  const rows = new Map();
  for (const file of files) {
    const id = key(file), row = rows.get(id) || {key: id, label: label(id), files: 0, added: 0, deleted: 0};
    row.files++; row.added += file.added || 0; row.deleted += file.deleted || 0;
    rows.set(id, row);
  }
  return [...rows.values()].sort((a, b) => b.added + b.deleted - a.added - a.deleted || b.files - a.files || a.label.localeCompare(b.label));
}

export function diffStats(files) {
  const created = files.filter(file => ['A', '?'].includes(file.status)).length, removed = files.filter(file => file.status === 'D').length;
  return {
    files: files.length, created, removed, modified: files.length - created - removed,
    added: files.reduce((sum, file) => sum + (file.added || 0), 0), deleted: files.reduce((sum, file) => sum + (file.deleted || 0), 0),
    // Binary files, images and text files over the size limit have no line diff to count.
    uncounted: files.filter(file => file.binary || file.limited).length,
    byKind: group(files, file => file.kind, kind => KIND_LABELS[kind] || kind),
    byType: group(files, file => fileType(file.path), type => type),
  };
}

export function signed(value) {return value > 0 ? `+${value.toLocaleString()}` : value < 0 ? `−${(-value).toLocaleString()}` : '0';}
