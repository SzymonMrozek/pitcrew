import test from 'node:test';
import assert from 'node:assert/strict';
import {configureModules, moduleFor, moduleLabel, moduleColors, MODULE_COLORS} from '../modules.mjs';

test('modules come from the configured layout patterns', () => {
  configureModules();
  assert.equal(moduleFor('Modules/Scenes/Activity/Implementation/Sources/ActivityInteractor.swift'), null);
  configureModules([
    '^Modules/(?<group>[^/]+)/(?<name>[^/]+)/(?:(?<target>Interface|Implementation|Testing)/)?.',
    '^(?<group>InternalPackages|App)/(?<name>[^/]+)/.',
    '(unclosed',
  ]);
  assert.deepEqual(moduleFor('Modules/Scenes/Activity/Implementation/Sources/ActivityInteractor.swift'), {name: 'Activity', target: 'Implementation', group: 'Scenes'});
  assert.deepEqual(moduleFor('Modules/Scenes/Activity/Project.swift'), {name: 'Activity', target: null, group: 'Scenes'});
  assert.deepEqual(moduleFor('Modules/Scenes/Activity/Interface'), {name: 'Activity', target: null, group: 'Scenes'});
  assert.deepEqual(moduleFor('Modules/UIComponents/ActivityList/Sources/List.swift'), {name: 'ActivityList', target: null, group: 'UIComponents'});
  assert.deepEqual(moduleFor('InternalPackages/Stubable/Package.swift'), {name: 'Stubable', target: null, group: 'InternalPackages'});
  assert.deepEqual(moduleFor('App/ExampleApp/Sources/App.swift'), {name: 'ExampleApp', target: null, group: 'App'});
  assert.equal(moduleFor('Tools/local-review/app.mjs'), null);
  assert.equal(moduleFor('Project.swift'), null);
  assert.equal(moduleLabel(moduleFor('Modules/Scenes/Activity/Interface/Sources/A.swift')), 'Activity · Interface');
  configureModules(['^Packages/(?<name>[^/]+)/']);
  assert.deepEqual(moduleFor('Packages/Core/Sources/A.swift'), {name: 'Core', target: null, group: ''});
});

test('module colors are stable and distinct within a review', () => {
  const names = Array.from({length: MODULE_COLORS}, (_, index) => `Module${index}`);
  const colors = moduleColors(names);
  assert.equal(new Set(colors.values()).size, MODULE_COLORS);
  assert.equal(moduleColors(['Module3']).get('Module3'), moduleColors(['Module3', 'Other']).get('Module3'));
  assert.equal(moduleColors([...names, 'Extra']).size, MODULE_COLORS + 1);
});
