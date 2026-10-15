import test from 'node:test';
import assert from 'node:assert/strict';
import {rankDefinitions} from '../definitions.mjs';
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
