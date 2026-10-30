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

const ELIXIR_DEFINERS = new Set(['def', 'defp', 'defmacro', 'defmacrop', 'defguard', 'defguardp', 'defdelegate']);

function previous(tokens, index) {
  while (--index >= 0) if (tokens[index].text.trim()) return index;
  return -1;
}

// Code navigation per highlighted language. Each provider looks at one highlighter token, with its line
// for context, and returns the declaration name it links to or the declared name whose callers it lists.
// `names` holds the declarations the server indexed for that language.
export const NAVIGATION = {
  swift: {
    label: 'Swift',
    link(tokens, index, names, line) {
      const token = tokens[index], before = tokens[previous(tokens, index)];
      // Imports name modules, not types.
      if (token.type === 'type' && names.has(token.text) && !/^\s*(?:@\w+\s+)*import\s/.test(line)) return {kind: 'definition', name: token.text};
      if (token.type === 'function' && before?.type === 'keyword' && before.text === 'func') return {kind: 'caller', name: token.text};
      return null;
    },
  },
  elixir: {
    label: 'Elixir',
    // Aliases resolve by their dotted suffix, so `Articles.create(` finds Later.Articles.create; calls
    // without a module resolve to functions of that name, the reading file's module first.
    link(tokens, index, names) {
      const token = tokens[index], at = previous(tokens, index), before = tokens[at];
      if (token.type === 'type') return names.has(token.text) ? {kind: 'definition', name: token.text} : null;
      if (token.type !== 'function') return null;
      if (before?.type === 'keyword' && ELIXIR_DEFINERS.has(before.text)) return {kind: 'caller', name: token.text};
      let name = token.text;
      if (before?.text.trimEnd().endsWith('.')) {
        const receiver = before.text === '.' ? tokens[at - 1] : null;
        if (receiver?.type === 'type') name = `${receiver.text}.${token.text}`;
        else if (receiver?.text !== '__MODULE__') return null;
      }
      return names.has(name) ? {kind: 'definition', name} : null;
    },
  },
};

export function navigationLinks(language, tokens, names = new Set()) {
  const provider = NAVIGATION[language];
  if (!provider) return [];
  const line = tokens.map(token => token.text).join(''), links = [];
  tokens.forEach((token, index) => {
    const link = token.type && provider.link(tokens, index, names, line);
    if (link) links.push({index, ...link});
  });
  return links;
}
