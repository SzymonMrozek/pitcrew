import test from 'node:test';
import assert from 'node:assert/strict';
import {navigationLinks, rankDefinitions} from '../definitions.mjs';
import {highlightLines} from '../highlight.mjs';
import {configureModules} from '../modules.mjs';

configureModules(['^Modules/(?<group>[^/]+)/(?<name>[^/]+)/(?:(?<target>Interface|Implementation|Testing)/)?.']);

test('definitions prefer the reading file, then its module, then nearby paths', () => {
  const locations = [
    {path: 'Modules/Scenes/Wallet/Implementation/Sources/WalletInteractor.swift', line: 4},
    {path: 'Modules/Scenes/Activity/Implementation/Sources/Other/State.swift', line: 2},
    {path: 'Modules/Scenes/Activity/Implementation/Sources/ActivityInteractor.swift', line: 9},
    {path: 'Modules/Scenes/Activity/Interface/Sources/State.swift', line: 1},
  ];
  assert.deepEqual(rankDefinitions(locations, 'Modules/Scenes/Activity/Implementation/Sources/ActivityInteractor.swift').map(l => l.path), [
    'Modules/Scenes/Activity/Implementation/Sources/ActivityInteractor.swift',
    'Modules/Scenes/Activity/Implementation/Sources/Other/State.swift',
    'Modules/Scenes/Activity/Interface/Sources/State.swift',
    'Modules/Scenes/Wallet/Implementation/Sources/WalletInteractor.swift',
  ]);
});

const links = (language, line, names) => navigationLinks(language, highlightLines([line], language)[0], new Set(names)).map(({kind, name}) => [kind, name]);

test('Swift links declared types outside imports and offers callers on func declarations', () => {
  assert.deepEqual(links('swift', 'func load(store: Store) -> Missing { make() }', ['Store']), [['caller', 'load'], ['definition', 'Store']]);
  assert.deepEqual(links('swift', '@testable import Store', ['Store']), []);
});

test('Elixir links modules and module-qualified or local calls, and offers callers on definitions', () => {
  const names = ['Later.Articles', 'Articles', 'Articles.create', 'helper', 'run'];
  assert.deepEqual(links('elixir', '  def create(attrs), do: Articles.create(attrs) |> helper()', names),
    [['caller', 'create'], ['definition', 'Articles'], ['definition', 'Articles.create'], ['definition', 'helper']]);
  assert.deepEqual(links('elixir', '  defp run, do: __MODULE__.helper(x) && socket.helper() && Enum.map(x) && Missing.run(x)', names),
    [['caller', 'run'], ['definition', 'helper']]);
  assert.deepEqual(links('elixir', '  alias Later.Articles', names), [['definition', 'Later.Articles']]);
});

test('languages without a navigation provider get no links', () => {
  assert.deepEqual(links('python', 'def load(store): Store()', ['Store', 'load']), []);
});
