import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubKubectlJob } from './build-stub-kubectl-job.ts';
import { buildStubRunner } from './build-stub-runner.ts';

test('it refuses a ConfigMap create while one of that name exists, as kubectl does', async () => {
  const kubectl = buildStubKubectlJob({
    jobName: 'nixie-sandbox-images-x7k2p',
    conditions: [[]],
    logs: '',
    configMaps: ['nixie-sandbox-images'],
  });

  const runner = buildStubRunner(kubectl.handler);

  const result = await runner.run(['kubectl', 'create', '--filename', '-'], {
    stdin: Buffer.from(
      JSON.stringify({ kind: 'ConfigMap', metadata: { name: 'nixie-sandbox-images' } }),
    ),
  });

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 1,
    stderr:
      'Error from server (AlreadyExists): error when creating "STDIN": configmaps "nixie-sandbox-images" already exists\n',
  });
});

test('it names a created Job by the name its generateName gives', async () => {
  const kubectl = buildStubKubectlJob({
    jobName: 'nixie-sandbox-images-x7k2p',
    conditions: [[]],
    logs: '',
  });

  const runner = buildStubRunner(kubectl.handler);

  const result = await runner.run(['kubectl', 'create', '--filename', '-', '--output', 'name'], {
    stdin: Buffer.from(
      JSON.stringify({ kind: 'Job', metadata: { generateName: 'nixie-sandbox-images-' } }),
    ),
  });

  expect(result.stdout.toString()).toBe('job.batch/nixie-sandbox-images-x7k2p\n');

  expect(kubectl.createdObjects).toStrictEqual([
    { kind: 'Job', metadata: { generateName: 'nixie-sandbox-images-' } },
  ]);
});

test("it answers each get with the next of the Job's conditions and keeps the last", async () => {
  const kubectl = buildStubKubectlJob({
    jobName: 'nixie-sandbox-images-x7k2p',
    conditions: [[], [{ type: 'Complete', status: 'True' }]],
    logs: '',
  });

  const runner = buildStubRunner(kubectl.handler);
  const get = ['kubectl', 'get', '--output', 'json', 'job.batch/nixie-sandbox-images-x7k2p'];
  const answers = [await runner.run(get), await runner.run(get), await runner.run(get)];

  expect(answers.map((answer) => answer.stdout.toString())).toStrictEqual([
    '{"kind":"Job","status":{"conditions":[]}}',
    '{"kind":"Job","status":{"conditions":[{"type":"Complete","status":"True"}]}}',
    '{"kind":"Job","status":{"conditions":[{"type":"Complete","status":"True"}]}}',
  ]);
});

test('it records the text and the mode of the file that KUBECONFIG names', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'stub-kubectl-job-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  await writeFile(join(directory, 'kubeconfig'), 'apiVersion: v1\n', { mode: 0o600 });

  const kubectl = buildStubKubectlJob({
    jobName: 'nixie-sandbox-images-x7k2p',
    conditions: [[]],
    logs: 'added nixie-fetch-77aa88bb99cc\n',
  });

  const runner = buildStubRunner(kubectl.handler);

  const result = await runner.run(['kubectl', 'logs', 'job.batch/nixie-sandbox-images-x7k2p'], {
    env: { KUBECONFIG: join(directory, 'kubeconfig') },
  });

  expect(result.stdout.toString()).toBe('added nixie-fetch-77aa88bb99cc\n');
  expect(kubectl.kubeconfigs).toStrictEqual([{ text: 'apiVersion: v1\n', mode: 0o600 }]);
});
