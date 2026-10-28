import { expect, test } from 'bun:test';
import { modelRoute } from './model-route.ts';

test('it builds the grant path that keeps an imp on its own route', () => {
  expect(modelRoute.buildGrantPaths('pv-0a1b2c3d-7')).toStrictEqual(['/pv-0a1b2c3d-7/**']);
});

test('it refuses to build a grant path for a name that is no route ID', () => {
  expect(() => modelRoute.buildGrantPaths('pv-0a1b2c3d-7/**')).toThrow();
});

test('it reads the imp and the path past the route from a model call path', () => {
  expect(modelRoute.parsePath('/pv-0a1b2c3d-7/v1/messages')).toStrictEqual({
    imp: 'pv-0a1b2c3d-7',
    path: '/v1/messages',
  });
});

test.each([
  ['an empty first segment', '//v1/messages'],
  ['an upper-case first segment', '/PV-0A1B2C3D-7/v1/messages'],
  ['a dot segment', '/../v1/messages'],
  ['the root', '/'],
])('it reads no route from a path with %s', (_label, pathname) => {
  expect(modelRoute.parsePath(pathname)).toBeNull();
});
