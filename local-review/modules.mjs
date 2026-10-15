// Repositories describe their module layout as regular expressions with named groups:
// `name` (required), `group` and `target` (optional), for example
// ^Modules/(?<group>[^/]+)/(?<name>[^/]+)/(?:(?<target>Interface|Implementation)/)?.
let patterns = [];

export function configureModules(sources = []) {
  patterns = sources.flatMap(source => {try {return [new RegExp(source)];} catch {return [];}});
}

export function moduleFor(path) {
  for (const pattern of patterns) {
    const groups = pattern.exec(path)?.groups;
    if (groups?.name) return {name: groups.name, target: groups.target || null, group: groups.group || ''};
  }
  return null;
}

export function moduleLabel(module) {return module.target ? `${module.name} · ${module.target}` : module.name;}

// Hues avoid green and red, which the diff reserves for additions and deletions.
export const MODULE_COLORS = 9;

function hash(text) {
  let value = 2166136261;
  for (const char of text) value = Math.imul(value ^ char.codePointAt(0), 16777619);
  return value >>> 0;
}

// Each module keeps a stable color across reviews; collisions within one review take the next free color.
export function moduleColors(names) {
  const colors = new Map(), used = new Set();
  for (const name of [...new Set(names)].sort()) {
    let color = hash(name) % MODULE_COLORS;
    for (let step = 0; step < MODULE_COLORS && used.has(color); step++) color = (color + 1) % MODULE_COLORS;
    colors.set(name, color); used.add(color);
    if (used.size === MODULE_COLORS) used.clear();
  }
  return colors;
}
