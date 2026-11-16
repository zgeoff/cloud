import { expect, onTestFinished, test } from 'bun:test';
import { readFileSync, readlinkSync } from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubNixieContainer } from './build-stub-nixie-container.ts';
import { buildStubRunner } from './build-stub-runner.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'build-stub-nixie-container-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it makes the folder a clone names, with the .bun-version it was given', async () => {
  const ctx = await setupTest();

  const runner = buildStubRunner(buildStubNixieContainer({ bunVersion: '1.5.0' }).handler);
  const checkout = join(ctx.directory, 'work', 'nixie');

  await runner.run(['git', 'clone', '--depth', '1', 'https://example.test/nixie.git', checkout]);

  expect(readFileSync(join(checkout, '.bun-version'), 'utf8')).toBe('1.5.0\n');
});

test('it makes .bun-version a symlink when given a target', async () => {
  const ctx = await setupTest();

  const target = join(ctx.directory, 'elsewhere');
  const runner = buildStubRunner(buildStubNixieContainer({ bunVersionLinksTo: target }).handler);
  const checkout = join(ctx.directory, 'work', 'nixie');

  await runner.run(['git', 'clone', '--depth', '1', 'https://example.test/nixie.git', checkout]);

  expect(readlinkSync(join(checkout, '.bun-version'))).toBe(target);
});

test("it records the kubeconfig the container's doctor gets, and gives the doctor its answer", async () => {
  const ctx = await setupTest();

  const kube = join(ctx.directory, 'kube');

  await mkdir(kube);
  await writeFile(join(kube, 'config'), 'apiVersion: v1\n', { mode: 0o600 });

  const stub = buildStubNixieContainer({ doctor: { exitCode: 1, stdout: 'failed\n' } });
  const runner = buildStubRunner(stub.handler);

  await runner.run(['docker', 'run', '--detach', '--volume', `${kube}:/kube:ro`, 'image']);

  const result = await runner.run([
    'docker',
    'exec',
    'box',
    'bun',
    'run',
    '--silent',
    'verify',
    'doctor',
    '--json',
    '--target',
    'prod',
  ]);

  expect({
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    kubeconfigs: stub.kubeconfigs,
  }).toStrictEqual({
    exitCode: 1,
    stdout: 'failed\n',
    kubeconfigs: [{ text: 'apiVersion: v1\n', mode: 0o600 }],
  });
});

test("it prints the image's Bun version", async () => {
  const runner = buildStubRunner(buildStubNixieContainer({ imageBunVersion: '1.4.3' }).handler);

  const result = await runner.run(['docker', 'exec', 'box', 'bun', '--version']);

  expect(result.stdout.toString()).toBe('1.4.3\n');
});

test('it leaves a call to another tool to the next handler', async () => {
  const runner = buildStubRunner(buildStubNixieContainer({}).handler);

  const result = await runner.run(['kubectl', 'version']);

  expect(result.exitCode).toBe(97);
});
