import { expect, test } from 'bun:test';
import { buildMCPAccountArgs } from './build-mcp-account-args.ts';

test('it names the account mcp-viewer and gives it the Viewer role', () => {
  expect(buildMCPAccountArgs()).toStrictEqual({ name: 'mcp-viewer', role: 'Viewer' });
});
