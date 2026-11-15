import { expect, onTestFinished, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubNixieCheckout } from './build-stub-nixie-checkout.ts';
import { buildStubRunner } from './build-stub-runner.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'build-stub-nixie-checkout-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it makes the folder a clone names', async () => {
  const ctx = await setupTest();

  const runner = buildStubRunner(buildStubNixieCheckout({}).handler);
  const checkout = join(ctx.directory, 'work', 'nixie');

  await runner.run(['git', 'clone', '--depth', '1', 'https://example.test/nixie.git', checkout]);

  expect(existsSync(checkout)).toBeTrue();
});

test('it records the kubeconfig the doctor gets, and gives the doctor its answer', async () => {
  const ctx = await setupTest();

  const kubeconfig = join(ctx.directory, 'kubeconfig.yaml');

  await writeFile(kubeconfig, 'apiVersion: v1\n', { mode: 0o600 });

  const checkout = buildStubNixieCheckout({ doctor: { exitCode: 1, stdout: 'failed\n' } });
  const runner = buildStubRunner(checkout.handler);

  const result = await runner.run(
    ['bun', 'run', '--silent', 'verify', 'doctor', '--json', '--target', 'prod'],
    { env: { NIXIE_PROD_KUBECONFIG: kubeconfig } },
  );

  expect({ exitCode: result.exitCode, stdout: result.stdout.toString() }).toStrictEqual({
    exitCode: 1,
    stdout: 'failed\n',
  });

  expect(checkout.kubeconfigs).toStrictEqual([{ text: 'apiVersion: v1\n', mode: 0o600 }]);
});

test('it leaves a call to another tool to the next handler', async () => {
  const runner = buildStubRunner(buildStubNixieCheckout({}).handler);

  const result = await runner.run(['kubectl', 'version']);

  expect(result.exitCode).toBe(97);
});
