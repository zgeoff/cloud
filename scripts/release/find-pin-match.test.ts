import { expect, test } from 'bun:test';
import { findPinMatch } from './find-pin-match.ts';

test('it finds the one matching line with each group and its span', () => {
  expect(
    findPinMatch(
      { 'images/demo/Dockerfile': 'FROM scratch\nARG DEMO_VERSION=1.4.2\nCMD ["demo"]\n' },
      {
        file: 'images/demo/Dockerfile',
        pattern: String.raw`^ARG DEMO_VERSION=(?<version>\d+\.\d+\.\d+)$`,
        parts: { version: { kind: 'version' } },
      },
    ),
  ).toStrictEqual({
    index: 1,
    text: 'ARG DEMO_VERSION=1.4.2',
    groups: { version: '1.4.2' },
    spans: { version: [17, 22] },
  });
});

test('it refuses a file the checkout lacks', () => {
  expect(
    findPinMatch(
      {},
      {
        file: 'images/demo/Dockerfile',
        pattern: String.raw`^ARG DEMO_VERSION=(?<version>\S+)$`,
        parts: {},
      },
    ),
  ).toStrictEqual(
    new Error(
      'images/demo/Dockerfile is missing: run this from the root of a zgeoff/cloud checkout',
    ),
  );
});

test('it refuses a pattern that two lines match', () => {
  expect(
    findPinMatch(
      { 'images/demo/Dockerfile': 'ARG DEMO_VERSION=1.4.2\nARG DEMO_VERSION=1.4.3\n' },
      {
        file: 'images/demo/Dockerfile',
        pattern: String.raw`^ARG DEMO_VERSION=(?<version>\S+)$`,
        parts: {},
      },
    ),
  ).toStrictEqual(
    new Error(
      String.raw`images/demo/Dockerfile has 2 lines that match '^ARG DEMO_VERSION=(?<version>\S+)$', want 1`,
    ),
  );
});

test('it refuses a pattern that no line matches', () => {
  expect(
    findPinMatch(
      { 'images/demo/Dockerfile': 'FROM scratch\n' },
      {
        file: 'images/demo/Dockerfile',
        pattern: String.raw`^ARG DEMO_VERSION=(?<version>\S+)$`,
        parts: {},
      },
    ),
  ).toStrictEqual(
    new Error(
      String.raw`images/demo/Dockerfile has 0 lines that match '^ARG DEMO_VERSION=(?<version>\S+)$', want 1`,
    ),
  );
});
