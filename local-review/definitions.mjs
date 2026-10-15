import {moduleFor} from './modules.mjs';

// Nested names such as `State` repeat across modules; prefer the declaration closest to the reader.
export function rankDefinitions(locations, fromPath = '') {
  const fromModule = moduleFor(fromPath)?.name, fromParts = fromPath.split('/');
  const shared = path => {const parts = path.split('/'); let count = 0; while (count < parts.length && parts[count] === fromParts[count]) count++; return count;};
  const rank = location => [location.path === fromPath ? 0 : 1, fromModule && moduleFor(location.path)?.name === fromModule ? 0 : 1, -shared(location.path)];
  return [...locations].sort((a, b) => {
    const left = rank(a), right = rank(b);
    for (let i = 0; i < left.length; i++) if (left[i] !== right[i]) return left[i] - right[i];
    return a.path.localeCompare(b.path) || a.line - b.line;
  });
}
