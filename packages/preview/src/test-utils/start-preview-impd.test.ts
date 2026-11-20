import { expect, test } from 'bun:test';
import { startPreviewImpd } from './start-preview-impd.ts';

async function setupTest() {
  const impd = await startPreviewImpd();

  return { impd };
}

test('it leaves the seeds out of the calls and lists the calls a test makes, with each imp name', async () => {
  const ctx = await setupTest();

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7' });
  await ctx.impd.client.imps.sleep({ name: 'pv-0a1b2c3d-7' });
  await ctx.impd.client.imps.list({});

  expect(ctx.impd.calls).toStrictEqual(['imps/sleep pv-0a1b2c3d-7', 'imps/list']);
});

test.each(['first', 'second'])(
  'it starts the %s of two tests with no imp, secret or call from the other',
  async () => {
    const ctx = await setupTest();
    const before = await ctx.impd.client.imps.list({});
    const secretsBefore = await ctx.impd.client.secrets.list({});

    await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7', grants: ['gh'] });

    expect(before).toStrictEqual([]);
    expect(secretsBefore).toStrictEqual([]);
    expect(ctx.impd.calls).toStrictEqual(['imps/list', 'secrets/list']);
  },
);

test('it leaves a call with the wrong token out of the calls', async () => {
  const ctx = await setupTest();

  const response = await fetch(`${ctx.impd.url}/rpc/imps/list`, {
    method: 'POST',
    headers: { authorization: 'Bearer imp_wrong.token', 'content-type': 'application/json' },
    body: JSON.stringify({ json: {} }),
  });

  expect(response.status).toBe(401);
  expect(ctx.impd.calls).toStrictEqual([]);
});

test('it reads the egress mode of each imp, open for one created with no policy', async () => {
  const ctx = await setupTest();

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7' });

  await ctx.impd.client.imps.setPolicy({
    name: 'pv-0a1b2c3d-7',
    policy: { mode: 'public', allow: [] },
  });

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-8' });

  const modes = await ctx.impd.readEgressModes();

  expect(modes).toStrictEqual(
    new Map([
      ['pv-0a1b2c3d-7', 'public'],
      ['pv-0a1b2c3d-8', 'open'],
    ]),
  );
});

test('it grants each seeded secret to its imp, and reads the paths of a filtered grant', async () => {
  const ctx = await setupTest();

  await ctx.impd.seedImp({ name: 'pv-0a1b2c3d-7', grants: ['gh', 'model'] });

  await ctx.impd.client.grants.add({
    name: 'pv-0a1b2c3d-7',
    secret: 'model',
    filter: { paths: ['/pv-0a1b2c3d-7/**'] },
  });

  const grants = await ctx.impd.client.grants.list({ name: 'pv-0a1b2c3d-7' });

  expect(grants).toStrictEqual(['gh', 'model']);

  expect(ctx.impd.readGrantPaths()).toStrictEqual(
    new Map([['pv-0a1b2c3d-7 model', ['/pv-0a1b2c3d-7/**']]]),
  );
});
