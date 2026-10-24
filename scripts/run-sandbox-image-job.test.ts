import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runSandboxImageJob } from './run-sandbox-image-job.ts';
import { buildStubClock } from './test-utils/build-stub-clock.ts';
import { buildStubKubectlJob } from './test-utils/build-stub-kubectl-job.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

async function setupTest() {
  const tempRoot = await mkdtemp(join(tmpdir(), 'sandbox-image-job-'));

  onTestFinished(() => rm(tempRoot, { recursive: true, force: true }));

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { tempRoot, printOut, printErr };
}

test('it creates the script ConfigMap and the Job, waits for the Job to complete, and removes the ConfigMap', async () => {
  const ctx = await setupTest();

  const clock = buildStubClock(0);

  const kubectl = buildStubKubectlJob({
    jobName: 'nixie-sandbox-images-x7k2p',
    conditions: [[], [{ type: 'Complete', status: 'True' }]],
    logs: 'held nixie-fetch-77aa88bb99cc\nadded nixie-conversation-5c0ffee0aa11\n',
  });

  const runner = buildStubRunner(kubectl.handler);

  const job = {
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: { generateName: 'nixie-sandbox-images-', namespace: 'nixie' },
    spec: {
      template: {
        spec: {
          volumes: [
            {
              name: 'script',
              configMap: {
                name: 'nixie-sandbox-images',
                items: [{ key: 'add-sandbox-images.js', path: 'add-sandbox-images.js' }],
              },
            },
          ],
        },
      },
    },
  };

  const exitCode = await runSandboxImageJob({
    env: { NIXIE_SANDBOX_IMAGES_JOB: JSON.stringify(job) },
    kubeconfig: 'apiVersion: v1\nkind: Config\n',
    run: runner.run,
    readScript: () => Promise.resolve('console.log("bundled");\n'),
    tempRoot: ctx.tempRoot,
    now: clock.now,
    sleep: clock.sleep,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(runner.calls.map((call) => [call.argv, call.stdin])).toStrictEqual([
    [
      [
        'kubectl',
        'delete',
        'configmap',
        'nixie-sandbox-images',
        '--namespace',
        'nixie',
        '--ignore-not-found',
      ],
      '',
    ],
    [
      ['kubectl', 'create', '--filename', '-'],
      JSON.stringify({
        apiVersion: 'v1',
        kind: 'ConfigMap',
        metadata: { name: 'nixie-sandbox-images', namespace: 'nixie' },
        data: { 'add-sandbox-images.js': 'console.log("bundled");\n' },
      }),
    ],
    [['kubectl', 'create', '--filename', '-', '--output', 'name'], JSON.stringify(job)],
    [
      [
        'kubectl',
        'get',
        '--output',
        'json',
        'job.batch/nixie-sandbox-images-x7k2p',
        '--namespace',
        'nixie',
      ],
      '',
    ],
    [
      [
        'kubectl',
        'get',
        '--output',
        'json',
        'job.batch/nixie-sandbox-images-x7k2p',
        '--namespace',
        'nixie',
      ],
      '',
    ],
    [['kubectl', 'logs', 'job.batch/nixie-sandbox-images-x7k2p', '--namespace', 'nixie'], ''],
    [
      [
        'kubectl',
        'delete',
        'configmap',
        'nixie-sandbox-images',
        '--namespace',
        'nixie',
        '--ignore-not-found',
      ],
      '',
    ],
  ]);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['run-sandbox-image-job: started job.batch/nixie-sandbox-images-x7k2p\n'],
    ['held nixie-fetch-77aa88bb99cc\nadded nixie-conversation-5c0ffee0aa11\n'],
    ["run-sandbox-image-job: job.batch/nixie-sandbox-images-x7k2p added nixie's sandbox images\n"],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(kubectl.configMaps).toBeEmpty();
});

test('it hands kubectl the kubeconfig in a file only its user reads, and removes the file after', async () => {
  const ctx = await setupTest();

  const clock = buildStubClock(0);

  const kubectl = buildStubKubectlJob({
    jobName: 'nixie-sandbox-images-x7k2p',
    conditions: [[{ type: 'Complete', status: 'True' }]],
    logs: '',
  });

  const runner = buildStubRunner(kubectl.handler);

  await runSandboxImageJob({
    env: {
      NIXIE_SANDBOX_IMAGES_JOB: JSON.stringify({
        metadata: { namespace: 'nixie' },
        spec: {
          template: {
            spec: {
              volumes: [
                {
                  name: 'script',
                  configMap: { name: 'nixie-sandbox-images', items: [{ key: 'add.js' }] },
                },
              ],
            },
          },
        },
      }),
    },
    kubeconfig:
      'apiVersion: v1\nkind: Config\nusers: [{name: admin, user: {token: kube-token-for-tests}}]\n',
    run: runner.run,
    readScript: () => Promise.resolve(''),
    tempRoot: ctx.tempRoot,
    now: clock.now,
    sleep: clock.sleep,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const leftover = await readdir(ctx.tempRoot);

  expect(kubectl.kubeconfigs).toStrictEqual(
    Array.from({ length: 6 }, () => ({
      text: 'apiVersion: v1\nkind: Config\nusers: [{name: admin, user: {token: kube-token-for-tests}}]\n',
      mode: 0o600,
    })),
  );

  expect(
    runner.calls.filter(
      (call) => call.argv.join(' ').includes('kube-token') || call.stdin.includes('kube-token'),
    ),
  ).toStrictEqual([]);

  expect(leftover).toStrictEqual([]);
});

test('it exits 1, prints the logs, and removes the ConfigMap when the Job fails', async () => {
  const ctx = await setupTest();

  const clock = buildStubClock(0);

  const kubectl = buildStubKubectlJob({
    jobName: 'nixie-sandbox-images-x7k2p',
    conditions: [[{ type: 'Failed', status: 'True', reason: 'BackoffLimitExceeded' }]],
    logs: 'run-sandbox-image-add: impd did not add the image nixie-conversation-5c0ffee0aa11\n',
  });

  const runner = buildStubRunner(kubectl.handler);

  const exitCode = await runSandboxImageJob({
    env: {
      NIXIE_SANDBOX_IMAGES_JOB: JSON.stringify({
        metadata: { namespace: 'nixie' },
        spec: {
          template: {
            spec: {
              volumes: [
                {
                  name: 'script',
                  configMap: { name: 'nixie-sandbox-images', items: [{ key: 'add.js' }] },
                },
              ],
            },
          },
        },
      }),
    },
    kubeconfig: 'apiVersion: v1\n',
    run: runner.run,
    readScript: () => Promise.resolve(''),
    tempRoot: ctx.tempRoot,
    now: clock.now,
    sleep: clock.sleep,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['run-sandbox-image-add: impd did not add the image nixie-conversation-5c0ffee0aa11\n'],
    [
      "run-sandbox-image-job: job.batch/nixie-sandbox-images-x7k2p failed (BackoffLimitExceeded), so nixie's sandbox images are not all in impd and nixie does not roll\n",
    ],
  ]);

  expect(kubectl.configMaps).toBeEmpty();
});

test('it exits 1 once the wait outlasts the Job deadline with no outcome', async () => {
  const ctx = await setupTest();

  const clock = buildStubClock(0);

  const kubectl = buildStubKubectlJob({
    jobName: 'nixie-sandbox-images-x7k2p',
    conditions: [[]],
    logs: '',
  });

  const runner = buildStubRunner(kubectl.handler);

  const exitCode = await runSandboxImageJob({
    env: {
      NIXIE_SANDBOX_IMAGES_JOB: JSON.stringify({
        metadata: { namespace: 'nixie' },
        spec: {
          template: {
            spec: {
              volumes: [
                {
                  name: 'script',
                  configMap: { name: 'nixie-sandbox-images', items: [{ key: 'add.js' }] },
                },
              ],
            },
          },
        },
      }),
    },
    kubeconfig: 'apiVersion: v1\n',
    run: runner.run,
    readScript: () => Promise.resolve(''),
    tempRoot: ctx.tempRoot,
    now: clock.now,
    sleep: clock.sleep,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(clock.now()).toBe(960_000);

  expect(ctx.printErr.mock.calls.at(-1)).toStrictEqual([
    "run-sandbox-image-job: job.batch/nixie-sandbox-images-x7k2p did not finish in 960 s, so nixie's sandbox images are not all in impd and nixie does not roll\n",
  ]);
});

test('it exits 1 with no Job when kubectl cannot create the ConfigMap', async () => {
  const ctx = await setupTest();

  const clock = buildStubClock(0);

  const runner = buildStubRunner(
    (call) => (call.argv[1] === 'delete' ? { stdout: '' } : undefined),
    (call) =>
      call.argv[1] === 'create'
        ? {
            exitCode: 1,
            stderr:
              'error: You must be logged in to the server (the server has asked for the client to provide credentials)\n',
          }
        : undefined,
  );

  const exitCode = await runSandboxImageJob({
    env: {
      NIXIE_SANDBOX_IMAGES_JOB: JSON.stringify({
        metadata: { namespace: 'nixie' },
        spec: {
          template: {
            spec: {
              volumes: [
                {
                  name: 'script',
                  configMap: { name: 'nixie-sandbox-images', items: [{ key: 'add.js' }] },
                },
              ],
            },
          },
        },
      }),
    },
    kubeconfig: 'apiVersion: v1\n',
    run: runner.run,
    readScript: () => Promise.resolve(''),
    tempRoot: ctx.tempRoot,
    now: clock.now,
    sleep: clock.sleep,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(runner.calls).toHaveLength(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      'run-sandbox-image-job: kubectl could not create the ConfigMap (exit 1): error: You must be logged in to the server (the server has asked for the client to provide credentials)\n',
    ],
  ]);
});

test('it exits 2 with no kubectl call when the Job has no script volume', async () => {
  const ctx = await setupTest();

  const clock = buildStubClock(0);
  const runner = buildStubRunner();

  const exitCode = await runSandboxImageJob({
    env: {
      NIXIE_SANDBOX_IMAGES_JOB: JSON.stringify({
        metadata: { namespace: 'nixie' },
        spec: { template: { spec: { volumes: [{ name: 'tmp', emptyDir: {} }] } } },
      }),
    },
    kubeconfig: 'apiVersion: v1\n',
    run: runner.run,
    readScript: () => Promise.resolve(''),
    tempRoot: ctx.tempRoot,
    now: clock.now,
    sleep: clock.sleep,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);
  expect(runner.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['run-sandbox-image-job: NIXIE_SANDBOX_IMAGES_JOB has no ConfigMap volume named script\n'],
  ]);
});

test('it exits 2 with no kubectl call when stdin holds no kubeconfig', async () => {
  const ctx = await setupTest();

  const clock = buildStubClock(0);
  const runner = buildStubRunner();

  const exitCode = await runSandboxImageJob({
    env: {
      NIXIE_SANDBOX_IMAGES_JOB: JSON.stringify({
        metadata: { namespace: 'nixie' },
        spec: {
          template: {
            spec: {
              volumes: [
                {
                  name: 'script',
                  configMap: { name: 'nixie-sandbox-images', items: [{ key: 'add.js' }] },
                },
              ],
            },
          },
        },
      }),
    },
    kubeconfig: '',
    run: runner.run,
    readScript: () => Promise.resolve(''),
    tempRoot: ctx.tempRoot,
    now: clock.now,
    sleep: clock.sleep,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);
  expect(runner.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['run-sandbox-image-job: the kubeconfig comes on stdin, which is empty\n'],
  ]);
});
