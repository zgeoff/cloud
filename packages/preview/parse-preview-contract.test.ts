import { expect, test } from 'bun:test';
import { parsePreviewContract } from './parse-preview-contract.ts';

test('it reads the port and the health path from the x-preview block', () => {
  expect(
    parsePreviewContract(
      'x-preview:\n  port: 3000\n  health: /healthz\nservices:\n  web:\n    image: nginx\n',
    ),
  ).toStrictEqual({ port: 3000, healthPath: '/healthz' });
});

test('it uses port 8080 and the root path for a file without the block', () => {
  expect(parsePreviewContract('services:\n  web:\n    image: nginx\n')).toStrictEqual({
    port: 8080,
    healthPath: '/',
  });
});

test.each([
  ['a port that is a string', 'x-preview:\n  port: "3000"\n', 'x-preview.port is not a TCP port'],
  ['a port past 65535', 'x-preview:\n  port: 70000\n', 'x-preview.port is not a TCP port'],
  [
    'a relative health path',
    'x-preview:\n  health: healthz\n',
    'x-preview.health is not a path that starts with /',
  ],
  ['a block that is a list', 'x-preview:\n  - 3000\n', 'x-preview is not a mapping'],
  ['a file that is a list', '- web\n', 'preview/compose.yaml is not a mapping'],
])('it rejects %s', (_label, yaml, message) => {
  expect(() => parsePreviewContract(yaml)).toThrowWithMessage(TypeError, message);
});
