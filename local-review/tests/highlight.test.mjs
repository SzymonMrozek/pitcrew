import test from 'node:test';
import assert from 'node:assert/strict';
import {languageFor, highlightLines, highlightRows} from '../highlight.mjs';

const types = tokens => tokens.filter(token => token.type).map(token => [token.type, token.text.trim()]);

test('languages cover the repository technologies', () => {
  const cases = {
    'Modules/A/B/Sources/A.swift': 'swift', 'Tools/local-review/app.mjs': 'javascript', 'Tools/x/server.py': 'python',
    'scripts/run.sh': 'shell', 'mise.toml': 'toml', 'Modules/A/B/swiftgen.yml': 'yaml', 'Package.resolved': 'json',
    'Tools/local-review/style.css': 'css', 'App/ExampleApp/Info.plist': 'xml', 'docs/tuist.md': 'markdown',
    'Tools/SessionBroker/Dockerfile': 'dockerfile', 'App/Config/Debug.xcconfig': 'xcconfig',
    'Resources/en.lproj/Localizable.strings': 'strings', '.gitignore': 'conf', 'Resources/image.pdf': null,
  };
  for (const [path, language] of Object.entries(cases)) assert.equal(languageFor(path), language, path);
  assert.equal(languageFor('.githooks/pre-commit', '#!/usr/bin/env bash'), 'shell');
  assert.equal(languageFor('.githooks/pre-push'), null);
});

test('Swift tokens distinguish keywords, types, calls, strings, attributes and comments', () => {
  const [line] = highlightLines(['@MainActor final class Foo: Bar { let x = make("a\\"b", 42) // done'], 'swift');
  assert.deepEqual(types(line), [['attribute', '@MainActor'], ['keyword', 'final'], ['keyword', 'class'], ['type', 'Foo'], ['type', 'Bar'], ['keyword', 'let'], ['function', 'make'], ['string', '"a\\"b"'], ['number', '42'], ['comment', '// done']]);
  assert.equal(line.map(token => token.text).join(''), '@MainActor final class Foo: Bar { let x = make("a\\"b", 42) // done');
});

test('identifiers containing keywords stay plain', () => {
  assert.deepEqual(types(highlightLines(['formatter.letter = forward'], 'swift')[0]), []);
});

test('block comments and multi-line strings continue across lines', () => {
  const lines = highlightLines(['let a = 1 /* start', 'still comment', 'end */ let b = """', 'text "quoted"', '"""'], 'swift');
  assert.deepEqual(types(lines[1]), [['comment', 'still comment']]);
  assert.deepEqual(types(lines[2]), [['comment', 'end */'], ['keyword', 'let'], ['string', '"""']]);
  assert.deepEqual(types(lines[3]), [['string', 'text "quoted"']]);
  assert.deepEqual(types(lines[4]), [['string', '"""']]);
});

test('escaped template delimiters do not close JavaScript template literals', () => {
  const lines = highlightLines(['const s = `a \\` b', 'c`; return s'], 'javascript');
  assert.deepEqual(types(lines[1]), [['string', 'c`'], ['keyword', 'return']]);
});

test('diff sides keep separate state and hunks restart it', () => {
  const rows = [
    {type: 'delete', text: '/* removed comment'}, {type: 'add', text: 'let value = 1'},
    {type: 'context', text: 'still old */ x'}, {type: 'hunk', text: '@@'}, {type: 'context', text: 'let y = 2'},
  ];
  const result = highlightRows(rows, 'swift');
  assert.equal(result[0].new, null);
  assert.equal(result[1].old, null);
  assert.deepEqual(types(result[2].old), [['comment', 'still old */']]);
  assert.deepEqual(types(result[2].new), []);
  assert.deepEqual(result[3], {});
  assert.deepEqual(types(result[4].old), [['keyword', 'let'], ['number', '2']]);
});

test('config formats mark keys, sections, variables and comments', () => {
  assert.deepEqual(types(highlightLines(['[tasks.review] # run'], 'toml')[0]), [['type', '[tasks.review]'], ['comment', '# run']]);
  assert.deepEqual(types(highlightLines(['  output: "x" # note'], 'yaml')[0]), [['property', 'output'], ['string', '"x"'], ['comment', '# note']]);
  assert.deepEqual(types(highlightLines(['{"key": true, "n": 1}'], 'json')[0]), [['property', '"key"'], ['literal', 'true'], ['property', '"n"'], ['number', '1']]);
  assert.deepEqual(types(highlightLines(['if [ -n "$X" ]; then echo ${#ARR} # c'], 'shell')[0]), [['keyword', 'if'], ['string', '"$X"'], ['keyword', 'then'], ['variable', '${#ARR}'], ['comment', '# c']]);
  assert.deepEqual(types(highlightLines(['"title" = "Hello";'], 'strings')[0]), [['property', '"title"'], ['string', '"Hello"']]);
  assert.deepEqual(types(highlightLines(['<key attr="v">'], 'xml')[0]), [['keyword', '<key'], ['property', 'attr'], ['string', '"v"'], ['keyword', '>']]);
});

test('very long lines stay plain', () => {
  const text = 'let '.repeat(1000);
  assert.deepEqual(highlightLines([text], 'swift')[0], [{text, type: null}]);
});
