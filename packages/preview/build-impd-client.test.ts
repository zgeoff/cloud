import { expect, test } from 'bun:test';
import { buildImpdClient } from './build-impd-client.ts';
import { NativeWebSocket } from './mocks/native-web-socket.ts';
import { startStubImpd } from './test-utils/start-stub-impd.ts';

function setupTest() {
  const impd = startStubImpd();
  const client = buildImpdClient(impd.url, impd.token, NativeWebSocket);

  return { impd, client };
}

test('#createImp creates an imp outside every backup, with the HTTP port it names', async () => {
  const ctx = setupTest();

  await ctx.client.createImp({
    name: 'pv-0a1b2c3d-7',
    image: 'base',
    memoryMib: 2048,
    httpPort: 3000,
  });

  expect(ctx.impd.imps.get('pv-0a1b2c3d-7')).toStrictEqual({
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    lastActiveAt: null,
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });
});

test('#findImp reads an imp with its last activity as a date', async () => {
  const ctx = setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'sleeping',
    lastActiveAt: '2026-10-01T08:30:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  const result = await ctx.client.findImp('pv-0a1b2c3d-7');

  expect(result).toStrictEqual({
    name: 'pv-0a1b2c3d-7',
    state: 'sleeping',
    lastActiveAt: new Date('2026-10-01T08:30:00.000Z'),
  });
});

test('#findImp returns null for an imp impd does not know', async () => {
  const ctx = setupTest();

  const result = await ctx.client.findImp('pv-0a1b2c3d-7');

  expect(result).toBeNull();
});

test('#sleepImp rejects with impd error code for an imp impd does not know', () => {
  const ctx = setupTest();

  expect(ctx.client.sleepImp('pv-0a1b2c3d-7')).rejects.toMatchObject({ code: 'NOT_FOUND' });
});

test('#readImps rejects with UNAUTHORIZED when impd refuses the token', () => {
  const ctx = setupTest();
  const client = buildImpdClient(ctx.impd.url, 'imp_wrong.token');

  expect(client.readImps()).rejects.toMatchObject({ code: 'UNAUTHORIZED' });
});

test('#runCommand returns the exit code and output of a guest command that requires the broker', async () => {
  const ctx = setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    lastActiveAt: null,
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  ctx.impd.answerCommand = () => ({ code: 3, stdout: 'compose: no such service: seed\n' });

  const result = await ctx.client.runCommand('pv-0a1b2c3d-7', ['docker', 'compose', 'up'], {
    requireBroker: true,
  });

  expect(result).toStrictEqual({ code: 3, output: 'compose: no such service: seed\n' });

  expect(ctx.impd.commands).toStrictEqual([
    { imp: 'pv-0a1b2c3d-7', argv: ['docker', 'compose', 'up'], require: ['broker'] },
  ]);
});

test('#runCommand rejects with impd error code for an imp impd does not know', () => {
  const ctx = setupTest();

  expect(ctx.client.runCommand('pv-0a1b2c3d-7', ['true'])).rejects.toMatchObject({
    code: 'NOT_FOUND',
  });
});
