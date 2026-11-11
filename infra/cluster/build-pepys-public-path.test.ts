import { expect, test } from 'bun:test';
import { buildPepysPublicPath } from './build-pepys-public-path.ts';

test('it anchors the one public route at both ends and leaves the private routes out', () => {
  expect(
    buildPepysPublicPath({
      routes: [
        { source: 'github', route: '/webhook/github', reach: 'public' },
        { source: 'telemetry', route: '/v1/logs', reach: 'private' },
      ],
      secretVariables: ['PEPYS_GITHUB_WEBHOOK_SECRET'],
    }),
  ).toBe('^(?:/webhook/github)$');
});

test('it joins several public routes and escapes a dot', () => {
  const path = buildPepysPublicPath({
    routes: [
      { source: 'github', route: '/webhook/github', reach: 'public' },
      { source: 'widgets', route: '/hooks/widget.v2', reach: 'public' },
    ],
    secretVariables: ['A_SECRET'],
  });

  expect(path).toBe(String.raw`^(?:/webhook/github|/hooks/widget\.v2)$`);
});

test.each([
  ['/webhook/github', true],
  ['/webhook/github/extra', false],
  ['/v1/logs', false],
  ['/prefix/webhook/github', false],
])('it gives a pattern that matches %s: %p', (path, matches) => {
  const pattern = buildPepysPublicPath({
    routes: [{ source: 'github', route: '/webhook/github', reach: 'public' }],
    secretVariables: ['A_SECRET'],
  });

  expect(new RegExp(pattern ?? '', 'u').test(path)).toBe(matches);
});

test('it returns nothing when no route is public', () => {
  expect(
    buildPepysPublicPath({
      routes: [{ source: 'telemetry', route: '/v1/logs', reach: 'private' }],
      secretVariables: ['A_SECRET'],
    }),
  ).toBeUndefined();
});
