import { expect, test } from 'bun:test';
import { createImpClient } from '@impz/client';
import { startScriptsImpd } from './start-scripts-impd.ts';

function setupTest() {
  const impd = startScriptsImpd();
  const client = createImpClient({ url: impd.url, token: impd.token });

  return { impd, client };
}

test('it lists each call a test makes, with the name and ref of an add', async () => {
  const ctx = setupTest();

  await ctx.client.images.list();

  const added = await ctx.client.images
    .add({ name: 'nixie-fetch', ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:aa' })
    .then(
      () => null,
      (error: unknown) => error,
    );

  expect(added).not.toBeNull();

  expect(ctx.impd.calls).toStrictEqual([
    'images/list',
    'images/add nixie-fetch ghcr.io/zgeoff/nixie-fetch@sha256:aa',
  ]);
});

test.each(['first', 'second'])(
  'it starts the %s of two tests with no image, fault or call from the other',
  async () => {
    const ctx = setupTest();

    const before = await ctx.client.images.list();

    await ctx.impd.seedImage('nixie-fetch');

    ctx.impd.fail('images/add', { code: 'FORBIDDEN', status: 403 });

    expect(before).toStrictEqual([]);
    expect(ctx.impd.calls).toStrictEqual(['images/list']);
  },
);

test('it answers a fault the test sets', () => {
  const ctx = setupTest();

  ctx.impd.fail('images/list', { code: 'FORBIDDEN', status: 403 });

  expect(ctx.client.images.list()).rejects.toMatchObject({ code: 'FORBIDDEN' });
});
