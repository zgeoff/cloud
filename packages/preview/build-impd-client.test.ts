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
    lastActiveAt: expect.toSatisfy((value: string) => !Number.isNaN(Date.parse(value))),
    httpPort: 3000,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });
});

test('#readImp reads an imp with its last activity as a date', async () => {
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

  const result = await ctx.client.readImp('pv-0a1b2c3d-7');

  expect(result).toStrictEqual({
    name: 'pv-0a1b2c3d-7',
    state: 'sleeping',
    lastActiveAt: new Date('2026-10-01T08:30:00.000Z'),
  });
});

test('#readImp returns null for an imp impd does not know', async () => {
  const ctx = setupTest();

  const result = await ctx.client.readImp('pv-0a1b2c3d-7');

  expect(result).toBeNull();
});

test('#sleepImp rejects with impd error code for an imp impd does not know', () => {
  const ctx = setupTest();

  expect(ctx.client.sleepImp('pv-0a1b2c3d-7')).rejects.toMatchObject({ code: 'NOT_FOUND' });
});

test('#sleepImp names impd and its error code in the message of a refusal', () => {
  const ctx = setupTest();

  expect(ctx.client.sleepImp('pv-0a1b2c3d-7')).rejects.toThrowWithMessage(
    Error,
    'impd NOT_FOUND: no imp named pv-0a1b2c3d-7',
  );
});

test('#readImps rejects with UNAUTHORIZED when impd refuses the token', () => {
  const ctx = setupTest();
  const client = buildImpdClient(ctx.impd.url, 'imp_wrong.token');

  expect(client.readImps()).rejects.toMatchObject({ code: 'UNAUTHORIZED' });
});

test('#installGrant adds the secret to an imp that lacks it', async () => {
  const ctx = setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  await ctx.client.installGrant('pv-0a1b2c3d-7', 'gh');

  expect(ctx.impd.imps.get('pv-0a1b2c3d-7')?.grants).toStrictEqual(['gh']);
});

test('#installGrant leaves an imp that holds the secret without a second grant', async () => {
  const ctx = setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['gh'],
  });

  await ctx.client.installGrant('pv-0a1b2c3d-7', 'gh');

  expect(ctx.impd.calls).toStrictEqual(['grants/list pv-0a1b2c3d-7']);
});

test('#installPathGrant narrows a grant the imp already holds to the paths it names', async () => {
  const ctx = setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: ['preview-model-counted'],
  });

  await ctx.client.installPathGrant('pv-0a1b2c3d-7', 'preview-model-counted', [
    '/pv-0a1b2c3d-7/**',
  ]);

  expect(ctx.impd.imps.get('pv-0a1b2c3d-7')?.grants).toStrictEqual(['preview-model-counted']);

  expect(ctx.impd.grantPaths.get('pv-0a1b2c3d-7 preview-model-counted')).toStrictEqual([
    '/pv-0a1b2c3d-7/**',
  ]);
});

test('#runCommand returns the exit code and output of a guest command that requires the broker', async () => {
  const ctx = setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
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

test('#runCommand returns the output of both streams in the order impd sent them', async () => {
  const ctx = setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  ctx.impd.answerCommand = () => ({
    code: 1,
    stdout: 'pulling seed\n',
    stderr: 'seed: exited 1\n',
  });

  const result = await ctx.client.runCommand('pv-0a1b2c3d-7', ['docker', 'compose', 'up']);

  expect(result).toStrictEqual({ code: 1, output: 'pulling seed\nseed: exited 1\n' });
});

test('#runCommand starts no command once its signal has aborted', async () => {
  const ctx = setupTest();

  ctx.impd.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  const result = ctx.client.runCommand('pv-0a1b2c3d-7', ['true'], { signal: AbortSignal.abort() });

  await expect(result).toReject();

  expect(ctx.impd.calls).toStrictEqual([]);
});

test('#runCommand rejects with impd error code for an imp impd does not know', () => {
  const ctx = setupTest();

  expect(ctx.client.runCommand('pv-0a1b2c3d-7', ['true'])).rejects.toMatchObject({
    code: 'NOT_FOUND',
  });
});
