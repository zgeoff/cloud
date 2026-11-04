import { expect, test } from 'bun:test';
import { buildImpdClient } from '../build-impd-client.ts';
import { server } from '../mocks/node.ts';
import { createImpdRefusalHandler } from './create-impd-refusal-handler.ts';
import { startStubImpd } from './start-stub-impd.ts';

function setupTest() {
  const impd = startStubImpd();

  return { impd, client: buildImpdClient(impd.url, impd.token) };
}

test('it refuses the named imp the set number of times, then passes its calls through', async () => {
  const ctx = setupTest();

  ctx.impd.imps.set('pv-4e5f6a7b-3', {
    name: 'pv-4e5f6a7b-3',
    state: 'sleeping',
    createdAt: '2026-09-02T00:00:00.000Z',
    lastActiveAt: '2026-10-14T08:00:00.000Z',
    lastRequestAt: null,
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  server.use(
    createImpdRefusalHandler({
      impdURL: ctx.impd.url,
      procedure: 'imps/setPolicy',
      imp: 'pv-4e5f6a7b-3',
      times: 1,
      code: 'MOVING',
      status: 409,
      message: 'The imp is moving between hosts',
      data: { retryAfterS: 5 },
    }),
  );

  const first = await ctx.client.updatePublicEgress('pv-4e5f6a7b-3').then(() => 'updated', String);

  await ctx.client.updatePublicEgress('pv-4e5f6a7b-3');

  expect(first).toBe('ImpdError: impd MOVING: The imp is moving between hosts');
  expect(ctx.impd.egressModes).toStrictEqual(new Map([['pv-4e5f6a7b-3', 'public']]));
});

test('it passes through a call that names another imp', async () => {
  const ctx = setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-17', {
    name: 'pv-0a1b2c3d-17',
    state: 'running',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: null,
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  server.use(
    createImpdRefusalHandler({
      impdURL: ctx.impd.url,
      procedure: 'imps/setPolicy',
      imp: 'pv-4e5f6a7b-3',
      times: 1,
      code: 'MOVING',
      status: 409,
      message: 'The imp is moving between hosts',
    }),
  );

  await ctx.client.updatePublicEgress('pv-0a1b2c3d-17');

  expect(ctx.impd.egressModes).toStrictEqual(new Map([['pv-0a1b2c3d-17', 'public']]));
});
