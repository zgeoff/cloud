import { expect, test } from 'bun:test';
import { hasSDKPinChange } from './has-sdk-pin-change.ts';

test('it finds a change to the catalog pin in the root package.json', () => {
  expect(
    hasSDKPinChange([
      {
        path: 'package.json',
        patch: [
          '@@ -20,7 +20,7 @@',
          '     "catalog": {',
          '-      "@anthropic-ai/claude-agent-sdk": "0.3.290",',
          '+      "@anthropic-ai/claude-agent-sdk": "0.3.301",',
          '       "@babel/core": "8.0.6",',
        ].join('\n'),
      },
    ]),
  ).toBeTrue();
});

test("it finds a change to the SDK's entry in bun.lock", () => {
  expect(
    hasSDKPinChange([
      {
        path: 'bun.lock',
        patch: [
          '@@ -310,7 +310,7 @@',
          '-    "@anthropic-ai/claude-agent-sdk": ["@anthropic-ai/claude-agent-sdk@0.3.290", "", {}, "sha512-a"],',
          '+    "@anthropic-ai/claude-agent-sdk": ["@anthropic-ai/claude-agent-sdk@0.3.301", "", {}, "sha512-b"],',
        ].join('\n'),
      },
    ]),
  ).toBeTrue();
});

test("it finds a change to a workspace package's own pin", () => {
  expect(
    hasSDKPinChange([
      {
        path: 'guests/conversation/package.json',
        patch:
          '@@ -5 +5 @@\n-    "@anthropic-ai/claude-agent-sdk": "0.3.290",\n+    "@anthropic-ai/claude-agent-sdk": "0.3.301",',
      },
    ]),
  ).toBeTrue();
});

test('it counts a manifest whose diff GitHub left out as a change', () => {
  expect(hasSDKPinChange([{ path: 'bun.lock', patch: null }])).toBeTrue();
});

test('it finds no change when the SDK appears only on unchanged lines of the diff', () => {
  expect(
    hasSDKPinChange([
      {
        path: 'package.json',
        patch: [
          '@@ -20,7 +20,7 @@',
          '       "@anthropic-ai/claude-agent-sdk": "0.3.290",',
          '-      "@babel/core": "8.0.6",',
          '+      "@babel/core": "8.0.7",',
        ].join('\n'),
      },
    ]),
  ).toBeFalse();
});

test('it finds no change in a file that is not a package.json or a bun.lock', () => {
  expect(
    hasSDKPinChange([
      {
        path: 'docs/sdk.md',
        patch:
          '@@ -1 +1 @@\n-"@anthropic-ai/claude-agent-sdk": "0.3.290"\n+"@anthropic-ai/claude-agent-sdk": "0.3.301"',
      },
      { path: 'docs/huge.json', patch: null },
    ]),
  ).toBeFalse();
});

test('it finds no change in a pull request that changes no file', () => {
  expect(hasSDKPinChange([])).toBeFalse();
});
