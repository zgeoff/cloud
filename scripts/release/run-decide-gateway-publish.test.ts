import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildRealProgramHandler } from '../test-utils/build-real-program-handler.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createCloudCheckout } from '../test-utils/create-cloud-checkout.ts';
import { runDecideGatewayPublish } from './run-decide-gateway-publish.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'decide-gateway-publish-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const output = join(directory, 'output');
  const summary = join(directory, 'summary');

  await writeFile(output, '');
  await writeFile(summary, '');

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { output, summary, printOut, printErr };
}

test('it publishes for a push to main that changes the image pins', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'images/atc-gateway/versions.env': 'GATEWAY_IMAGE_TAG=7.1.0\n',
  });

  const before = await checkout.git(['-C', checkout.seed, 'rev-parse', 'HEAD']);

  await writeFile(
    join(checkout.seed, 'images/atc-gateway/versions.env'),
    'GATEWAY_IMAGE_TAG=7.2.0\n',
  );

  await checkout.git(['-C', checkout.seed, 'commit', '-qam', 'bump the gateway to 7.2.0']);
  await checkout.git(['-C', checkout.seed, 'push', '-q', 'origin', 'main']);

  const sha = await checkout.git(['-C', checkout.seed, 'rev-parse', 'HEAD']);

  // the workflow's checkout holds only the pushed commit
  await checkout.git(['-C', checkout.clone, 'fetch', '-q', '--depth=1', 'origin', sha]);
  await checkout.git(['-C', checkout.clone, 'checkout', '-q', sha]);

  const stub = buildStubRunner(buildRealProgramHandler(['git'], checkout.env));

  const status = await runDecideGatewayPublish({
    env: {
      ...checkout.env,
      EVENT: 'push',
      REF: 'refs/heads/main',
      BEFORE: before,
      SHA: sha,
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: checkout.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const output = await readFile(ctx.output, 'utf8');
  const summary = await readFile(ctx.summary, 'utf8');

  expect(status).toBe(0);
  expect(output).toBe('publish=true\n');
  expect(summary).toBe('publish: the push to main changes images/atc-gateway/versions.env\n');
  expect(ctx.printErr.mock.calls).toStrictEqual([]);
});

test('it skips a push to main that leaves the image pins as they were', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'images/atc-gateway/versions.env': 'GATEWAY_IMAGE_TAG=7.1.0\n',
    'images/atc-gateway/Dockerfile': 'FROM scratch\n',
  });

  const before = await checkout.git(['-C', checkout.seed, 'rev-parse', 'HEAD']);

  await writeFile(join(checkout.seed, 'images/atc-gateway/Dockerfile'), 'FROM busybox\n');

  await checkout.git(['-C', checkout.seed, 'commit', '-qam', 'change the base image']);
  await checkout.git(['-C', checkout.seed, 'push', '-q', 'origin', 'main']);

  const sha = await checkout.git(['-C', checkout.seed, 'rev-parse', 'HEAD']);

  await checkout.git(['-C', checkout.clone, 'fetch', '-q', '--depth=1', 'origin', sha]);
  await checkout.git(['-C', checkout.clone, 'checkout', '-q', sha]);

  const stub = buildStubRunner(buildRealProgramHandler(['git'], checkout.env));

  const status = await runDecideGatewayPublish({
    env: {
      ...checkout.env,
      EVENT: 'push',
      REF: 'refs/heads/main',
      BEFORE: before,
      SHA: sha,
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: checkout.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const output = await readFile(ctx.output, 'utf8');

  expect(status).toBe(0);
  expect(output).toBe('publish=false\n');

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['skip: the push to main leaves images/atc-gateway/versions.env as it was\n'],
  ]);
});

test('it never publishes for a pull request, and runs no git', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const status = await runDecideGatewayPublish({
    env: {
      EVENT: 'pull_request',
      REF: 'refs/pull/412/merge',
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: '/nonexistent',
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const output = await readFile(ctx.output, 'utf8');

  expect(status).toBe(0);
  expect(output).toBe('publish=false\n');
  expect(stub.calls).toStrictEqual([]);
});

test('it fails a push whose commit before is not a full commit, and writes no output', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const status = await runDecideGatewayPublish({
    env: {
      EVENT: 'push',
      REF: 'refs/heads/main',
      BEFORE: '0000000000000000000000000000000000000000',
      SHA: 'c5bea94080fdde9e21e9720295c1ca727302662e',
      GITHUB_OUTPUT: ctx.output,
      GITHUB_STEP_SUMMARY: ctx.summary,
    },
    cwd: '/nonexistent',
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const output = await readFile(ctx.output, 'utf8');

  expect(status).toBe(1);
  expect(output).toBe('');

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      "a push needs BEFORE and SHA as full commits, not '0000000000000000000000000000000000000000' and 'c5bea94080fdde9e21e9720295c1ca727302662e'\n",
    ],
  ]);
});

test('it fails without the runner output file', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const status = await runDecideGatewayPublish({
    env: { EVENT: 'push', REF: 'refs/heads/main', GITHUB_STEP_SUMMARY: ctx.summary },
    cwd: '/nonexistent',
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['GITHUB_OUTPUT must be set, as the workflow sets it\n'],
  ]);
});
