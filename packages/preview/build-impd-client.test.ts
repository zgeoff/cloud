import { expect, test } from 'bun:test';
import { buildImpdClient } from './build-impd-client.ts';
import { startPreviewImpd } from './src/test-utils/start-preview-impd.ts';
import { startStubImpd } from './src/test-utils/start-stub-impd.ts';

function setupTest() {
  const impd = startPreviewImpd();
  const client = buildImpdClient(impd.url, impd.token);

  return { impd, client };
}

test('#createImp creates an elastic imp outside every backup, with the memory and HTTP port it names', async () => {
  const ctx = setupTest();

  await ctx.client.createImp({
    name: 'pv-0a1b2c3d-7',
    image: 'base',
    memoryMib: 1024,
    maxMemoryMib: 2048,
    httpPort: 3000,
  });

  const imp = await ctx.impd.client.imps.get({ name: 'pv-0a1b2c3d-7' });

  expect({
    name: imp.name,
    state: imp.state,
    httpPort: imp.httpPort,
    image: imp.image,
    memoryMib: imp.memoryMib,
    maxMemoryMib: imp.maxMemoryMib,
    backup: imp.backup,
  }).toStrictEqual({
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    httpPort: 3000,
    image: 'base',
    memoryMib: 1024,
    maxMemoryMib: 2048,
    backup: false,
  });
});

test('#createImp creates the imp under the public egress policy, which keeps its guest off private addresses', async () => {
  const ctx = setupTest();

  await ctx.client.createImp({
    name: 'pv-0a1b2c3d-7',
    image: 'base',
    memoryMib: 1024,
    maxMemoryMib: 2048,
    httpPort: 3000,
  });

  const modes = await ctx.impd.readEgressModes();

  expect(modes).toStrictEqual(new Map([['pv-0a1b2c3d-7', 'public']]));
});

test('#updatePublicEgress puts an existing imp under the public egress policy', async () => {
  const ctx = setupTest();

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7', httpPort: 3000, state: 'sleeping' });
  await ctx.client.updatePublicEgress('pv-0a1b2c3d-7');

  const modes = await ctx.impd.readEgressModes();

  expect(modes).toStrictEqual(new Map([['pv-0a1b2c3d-7', 'public']]));
});

test('#readImp reads an imp with no proxied request, as an impd before 6.4.0 reports it, as last used at its last activity', async () => {
  const ctx = setupTest();

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7' });

  const held = await ctx.impd.client.imps.get({ name: 'pv-0a1b2c3d-7' });
  const result = await ctx.client.readImp('pv-0a1b2c3d-7');

  expect(result).toStrictEqual({
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    lastUsedAt: held.lastActiveAt,
  });
});

test('#readImp reads an imp as last used at its last proxied request, whatever its last activity', async () => {
  // the package's impd has no wake proxy, so nothing sets an imp's last request time
  const stub = startStubImpd();
  const client = buildImpdClient(stub.url, stub.token);

  stub.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'sleeping',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-01T09:00:00.000Z',
    lastRequestAt: '2026-10-01T08:30:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  const result = await client.readImp('pv-0a1b2c3d-7');

  expect(result).toStrictEqual({
    name: 'pv-0a1b2c3d-7',
    state: 'sleeping',
    lastUsedAt: new Date('2026-10-01T08:30:00.000Z'),
  });
});

test('#readImp returns null for an imp impd does not know', async () => {
  const ctx = setupTest();

  const result = await ctx.client.readImp('pv-0a1b2c3d-7');

  expect(result).toBeNull();
});

test('#sleepImp rejects with impd error code for an imp impd does not know', async () => {
  const ctx = setupTest();

  await expect(ctx.client.sleepImp('pv-0a1b2c3d-7')).rejects.toMatchObject({ code: 'NOT_FOUND' });
});

test('#sleepImp names impd and its error code in the message of a refusal', async () => {
  const ctx = setupTest();

  await expect(ctx.client.sleepImp('pv-0a1b2c3d-7')).rejects.toThrowWithMessage(
    Error,
    'impd NOT_FOUND: imp pv-0a1b2c3d-7 not found',
  );
});

test('#readImps rejects with UNAUTHORIZED when impd refuses the token', async () => {
  const ctx = setupTest();
  const client = buildImpdClient(ctx.impd.url, 'imp_wrong.token');

  await expect(client.readImps()).rejects.toMatchObject({ code: 'UNAUTHORIZED' });
});

test('#installGrant adds the secret to an imp that lacks it', async () => {
  const ctx = setupTest();

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7' });
  await ctx.impd.seedSecret('gh');
  await ctx.client.installGrant('pv-0a1b2c3d-7', 'gh');

  const grants = await ctx.impd.client.grants.list({ name: 'pv-0a1b2c3d-7' });

  expect(grants).toStrictEqual(['gh']);
});

test('#installGrant leaves an imp that holds the secret without a second grant', async () => {
  const ctx = setupTest();

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7', grants: ['gh'] });
  await ctx.client.installGrant('pv-0a1b2c3d-7', 'gh');

  expect(ctx.impd.calls).toStrictEqual(['grants/list pv-0a1b2c3d-7']);
});

test('#removeGrantsExcept removes every grant of the imp outside the kept secrets', async () => {
  const ctx = setupTest();

  await ctx.impd.seedImp({
    name: 'pv-0a1b2c3d-7',
    grants: ['gh', 'model-sonnet', 'model-sonnet-counted', 'search-api'],
  });

  await ctx.client.removeGrantsExcept('pv-0a1b2c3d-7', ['gh', 'model-sonnet-counted']);

  const grants = await ctx.impd.client.grants.list({ name: 'pv-0a1b2c3d-7' });

  expect(grants).toStrictEqual(['gh', 'model-sonnet-counted']);
});

test('#removeGrantsExcept leaves an imp that holds only kept secrets without a removal', async () => {
  const ctx = setupTest();

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7', grants: ['gh'] });
  await ctx.client.removeGrantsExcept('pv-0a1b2c3d-7', ['gh', 'model-sonnet-counted']);

  expect(ctx.impd.calls).toStrictEqual(['grants/list pv-0a1b2c3d-7']);
});

test('#installPathGrant narrows a grant the imp already holds to the paths it names', async () => {
  const ctx = setupTest();

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7', grants: ['preview-model-counted'] });

  await ctx.client.installPathGrant('pv-0a1b2c3d-7', 'preview-model-counted', [
    '/pv-0a1b2c3d-7/**',
  ]);

  const grants = await ctx.impd.client.grants.list({ name: 'pv-0a1b2c3d-7' });

  expect(grants).toStrictEqual(['preview-model-counted']);

  const paths = await ctx.impd.readGrantPaths();

  expect(paths).toStrictEqual(
    new Map([['pv-0a1b2c3d-7 preview-model-counted', ['/pv-0a1b2c3d-7/**']]]),
  );
});

test('#runCommand returns the exit code and output of a guest command that requires the broker', async () => {
  // the package's impd runs no command, so a stand-in answers the exec
  const stub = startStubImpd();
  const client = buildImpdClient(stub.url, stub.token);

  stub.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  stub.answerCommand = () => ({ code: 3, stdout: 'compose: no such service: seed\n' });

  const result = await client.runCommand('pv-0a1b2c3d-7', ['docker', 'compose', 'up'], {
    requireBroker: true,
  });

  expect(result).toStrictEqual({ code: 3, output: 'compose: no such service: seed\n' });

  expect(stub.commands).toStrictEqual([
    { imp: 'pv-0a1b2c3d-7', argv: ['docker', 'compose', 'up'], require: ['broker'] },
  ]);
});

test('#runCommand returns the output of both streams in the order impd sent them', async () => {
  // the package's impd runs no command, so a stand-in answers the exec
  const stub = startStubImpd();
  const client = buildImpdClient(stub.url, stub.token);

  stub.imps.set('pv-0a1b2c3d-7', {
    name: 'pv-0a1b2c3d-7',
    state: 'running',
    createdAt: '2026-09-01T00:00:00.000Z',
    lastActiveAt: '2026-10-15T08:00:00.000Z',
    lastRequestAt: '2026-10-15T08:00:00.000Z',
    httpPort: 8080,
    image: 'base',
    memoryMib: 2048,
    backup: false,
    grants: [],
  });

  stub.answerCommand = () => ({
    code: 1,
    stdout: 'pulling seed\n',
    stderr: 'seed: exited 1\n',
  });

  const result = await client.runCommand('pv-0a1b2c3d-7', ['docker', 'compose', 'up']);

  expect(result).toStrictEqual({ code: 1, output: 'pulling seed\nseed: exited 1\n' });
});

test('#runCommand starts no command once its signal has aborted', async () => {
  const ctx = setupTest();

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7' });

  const result = ctx.client.runCommand('pv-0a1b2c3d-7', ['true'], { signal: AbortSignal.abort() });

  await expect(result).toReject();

  expect(ctx.impd.calls).toStrictEqual([]);
});

test('#runCommand rejects with impd error code for an imp impd does not know', async () => {
  const ctx = setupTest();

  await expect(ctx.client.runCommand('pv-0a1b2c3d-7', ['true'])).rejects.toMatchObject({
    code: 'NOT_FOUND',
  });
});
