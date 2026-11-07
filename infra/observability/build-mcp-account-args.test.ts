import { expect, test } from 'bun:test';
import { buildMCPAccountArgs } from './build-mcp-account-args.ts';

test('it names the account mcp-viewer and gives it the Viewer role, so it reads and cannot write', () => {
  expect(buildMCPAccountArgs()).toStrictEqual({ name: 'mcp-viewer', role: 'Viewer' });
});
