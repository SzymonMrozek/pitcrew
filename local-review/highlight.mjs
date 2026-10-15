// Dependency-free highlighting for the languages this repository uses. Tokens are
// rendered as text nodes, so highlighting never interprets diff content as HTML.
const words = list => new Set(list.split(' '));
const block = (type, start, end, escape = false) => ({type, start, end, escape});
const rule = (type, pattern, options = {}) => ({type, pattern: new RegExp(pattern.source, 'y'), ...options});
const NUMBER = rule('number', /-?(?:0x[\da-fA-F_]+|0b[01_]+|0o[0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b/);
const WORD = rule('word', /[A-Za-z_][\w]*/);
const DOUBLE_STRING = rule('string', /"(?:[^"\\]|\\.)*"?/);
const SINGLE_STRING = rule('string', /'(?:[^'\\]|\\.)*'?/);
const HASH_COMMENT = rule('comment', /#.*/);
const SLASH_COMMENT = rule('comment', /\/\/.*/);
const BLOCK_COMMENT = block('comment', '/*', '*/');
const XML = {rules: [block('comment', '<!--', '-->'), rule('keyword', /<\/?[\w:.-]+|\/?>/), rule('property', /[\w:.-]+(?==)/), DOUBLE_STRING, SINGLE_STRING, rule('literal', /&#?\w+;/)]};

export const LANGUAGES = {
  swift: {
    rules: [BLOCK_COMMENT, SLASH_COMMENT, block('string', '"""', '"""'), DOUBLE_STRING, rule('attribute', /@\w+/), rule('keyword', /#\w+/), NUMBER, WORD],
    keywords: words('actor any as associatedtype async await break case catch class consume continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let macro mutating nonisolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return sending set some static struct subscript switch throw throws try typealias unowned var weak where while willSet'),
    literals: words('true false nil self Self super'), types: true, calls: true,
  },
  javascript: {
    rules: [BLOCK_COMMENT, SLASH_COMMENT, block('string', '`', '`', true), DOUBLE_STRING, SINGLE_STRING, NUMBER, WORD],
    keywords: words('async await break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch throw try typeof var void while with yield'),
    literals: words('true false null undefined this NaN Infinity'), types: true, calls: true,
  },
  python: {
    rules: [HASH_COMMENT, block('string', '"""', '"""', true), block('string', "'''", "'''", true), DOUBLE_STRING, SINGLE_STRING, rule('attribute', /@[\w.]+/), NUMBER, WORD],
    keywords: words('and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case'),
    literals: words('True False None self cls'), types: true, calls: true,
  },
  shell: {
    rules: [rule('variable', /\$(?:\{[^}]*\}|\(\(?|[\w]+|[#?@*$!-])/), rule('comment', /(?:^|(?<=\s))#.*/), DOUBLE_STRING, SINGLE_STRING, NUMBER, rule('word', /[A-Za-z_][\w-]*/)],
    keywords: words('if then else elif fi for while until do done case esac function in select return local export readonly declare set unset shift source exit trap break continue eval exec'),
    literals: words('true false'), calls: false,
  },
  yaml: {
    rules: [rule('comment', /(?:^|(?<=\s))#.*/), rule('property', /[\w./-]+(?=\s*:(?:\s|$))/), DOUBLE_STRING, SINGLE_STRING, rule('attribute', /[&*][\w-]+/), NUMBER, rule('word', /[A-Za-z_][\w-]*/)],
    keywords: new Set(), literals: words('true false yes no null on off'),
  },
  toml: {
    rules: [HASH_COMMENT, rule('type', /\[\[?[^\]]+\]\]?/, {lineStart: true}), block('string', '"""', '"""', true), block('string', "'''", "'''"), rule('property', /[\w."-]+(?=\s*=)/), DOUBLE_STRING, SINGLE_STRING, NUMBER, WORD],
    keywords: new Set(), literals: words('true false'),
  },
  json: {
    rules: [rule('property', /"(?:[^"\\]|\\.)*"(?=\s*:)/), DOUBLE_STRING, NUMBER, WORD],
    keywords: new Set(), literals: words('true false null'),
  },
  css: {
    rules: [BLOCK_COMMENT, rule('keyword', /@[\w-]+/), rule('property', /--?[\w-]+(?=\s*:)|[a-z-]+(?=\s*:[^:]*;)/), DOUBLE_STRING, SINGLE_STRING, rule('number', /#[\da-fA-F]{3,8}\b|-?\d*\.?\d+(?:px|em|rem|vh|vw|%|s|ms|deg|fr)?/)],
  },
  xml: XML,
  markdown: {
    rules: [block('string', '```', '```'), rule('keyword', /#{1,6}\s.*/, {lineStart: true}), rule('keyword', /(?:[-*+]|\d+\.)(?=\s)/, {lineStart: true}), rule('string', /`[^`]+`/), rule('property', /\]\([^)]*\)/), rule('attribute', /\*\*[^*]+\*\*/)],
  },
  dockerfile: {
    rules: [HASH_COMMENT, rule('keyword', /[A-Za-z]+/, {lineStart: true, match: text => /^(ADD|ARG|CMD|COPY|ENTRYPOINT|ENV|EXPOSE|FROM|HEALTHCHECK|LABEL|ONBUILD|RUN|SHELL|STOPSIGNAL|USER|VOLUME|WORKDIR)$/i.test(text)}), rule('variable', /\$(?:\{[^}]*\}|\w+)/), DOUBLE_STRING, SINGLE_STRING, NUMBER],
  },
  xcconfig: {
    rules: [SLASH_COMMENT, rule('keyword', /#include\??/), rule('property', /[\w[\]=*]+(?=\s*=)/, {lineStart: true}), rule('variable', /\$[({][\w:]+[)}]/), DOUBLE_STRING, NUMBER],
  },
  strings: {
    rules: [BLOCK_COMMENT, SLASH_COMMENT, rule('property', /"(?:[^"\\]|\\.)*"(?=\s*=)/), DOUBLE_STRING],
  },
  conf: {
    rules: [rule('comment', /[#;].*/, {lineStart: true}), rule('type', /\[[^\]]+\]/, {lineStart: true}), rule('property', /[\w.-]+(?=\s*=)/, {lineStart: true}), DOUBLE_STRING, SINGLE_STRING],
  },
  proto: {
    rules: [BLOCK_COMMENT, SLASH_COMMENT, DOUBLE_STRING, NUMBER, WORD],
    keywords: words('syntax package import option message enum service rpc returns stream repeated optional required oneof map reserved extend public weak to max'),
    literals: words('true false'), types: true,
  },
};

const EXTENSIONS = {
  swift: 'swift', js: 'javascript', mjs: 'javascript', cjs: 'javascript', ts: 'javascript', py: 'python',
  sh: 'shell', bash: 'shell', zsh: 'shell', yml: 'yaml', yaml: 'yaml', toml: 'toml', json: 'json', resolved: 'json',
  css: 'css', html: 'xml', xml: 'xml', plist: 'xml', entitlements: 'xml', stringsdict: 'xml', svg: 'xml',
  storyboard: 'xml', xib: 'xml', md: 'markdown', xcconfig: 'xcconfig', strings: 'strings', proto: 'proto',
  ini: 'conf', gitignore: 'conf', gitattributes: 'conf', gitmodules: 'conf', dockerignore: 'conf', swiftformat: 'conf', swiftlint: 'yaml',
};

export function languageFor(path, firstLine = '') {
  const name = path.split('/').pop(), extension = name.includes('.') ? name.split('.').pop().toLowerCase() : '';
  if (/^dockerfile$/i.test(name)) return 'dockerfile';
  if (EXTENSIONS[extension]) return EXTENSIONS[extension];
  const shebang = firstLine.match(/^#!.*\b(sh|bash|zsh|python3?|node)\b/);
  return shebang ? {sh: 'shell', bash: 'shell', zsh: 'shell', python: 'python', python3: 'python', node: 'javascript'}[shebang[1]] : null;
}

const MAX_LINE = 2000;

function closing(text, from, open) {
  for (let i = from; i < text.length; i++) {
    if (open.escape && text[i] === '\\') {i++; continue;}
    if (text.startsWith(open.end, i)) return i;
  }
  return -1;
}

function classify(spec, token, text, end) {
  if (spec.keywords?.has(token)) return 'keyword';
  if (spec.literals?.has(token)) return 'literal';
  if (spec.types && /^[A-Z]/.test(token)) return 'type';
  if (spec.calls && /^\s*\(/.test(text.slice(end))) return 'function';
  return null;
}

// Keeps multi-line comment and string state across consecutive lines of one diff side.
export function createHighlighter(language) {
  const spec = LANGUAGES[language];
  let open = null;
  return {
    reset() {open = null;},
    line(text) {
      if (!spec || text.length > MAX_LINE) return [{text, type: null}];
      const tokens = [];
      const push = (value, type) => {if (!value) return; const last = tokens.at(-1); if (last && last.type === type) last.text += value; else tokens.push({text: value, type});};
      let i = 0;
      while (i < text.length) {
        if (open) {
          const end = closing(text, i, open);
          if (end < 0) {push(text.slice(i), open.type); break;}
          push(text.slice(i, end + open.end.length), open.type); i = end + open.end.length; open = null; continue;
        }
        let matched = false;
        for (const candidate of spec.rules) {
          if (candidate.lineStart && text.slice(0, i).trim()) continue;
          if (candidate.start) {
            if (!text.startsWith(candidate.start, i)) continue;
            push(candidate.start, candidate.type); i += candidate.start.length; open = candidate; matched = true; break;
          }
          candidate.pattern.lastIndex = i;
          const match = candidate.pattern.exec(text)?.[0];
          if (!match || candidate.match && !candidate.match(match)) continue;
          push(match, candidate.type === 'word' ? classify(spec, match, text, i + match.length) : candidate.type);
          i += match.length; matched = true; break;
        }
        if (!matched) push(text[i++], null);
      }
      return tokens;
    },
  };
}

export function highlightLines(lines, language) {
  const highlighter = createHighlighter(language);
  return lines.map(line => highlighter.line(line));
}

// Old and new sides keep separate state; hunks restart it because unchanged lines between them are omitted.
export function highlightRows(rows, language) {
  const old = createHighlighter(language), next = createHighlighter(language);
  return rows.map(row => {
    if (row.type === 'hunk') {old.reset(); next.reset(); return {};}
    return {old: row.type === 'add' ? null : old.line(row.text), new: row.type === 'delete' ? null : next.line(row.text)};
  });
}
