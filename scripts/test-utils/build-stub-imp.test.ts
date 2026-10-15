import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubImp } from './build-stub-imp.ts';
import { buildStubRunner } from './build-stub-runner.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'build-stub-imp-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  return { dir };
}

test('it lists each image with the name, ref and digest the scripts read', async () => {
  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'image', 'ls', '--json']);

  expect(result.stdout.toString()).toBe(
    '[{"name":"agent-abc1234","ref":"imp/agent-abc1234:latest","digest":"imp-build-2"}]\n',
  );
});

test('it builds an image from a folder and reads the folder’s Dockerfile when the build runs', async () => {
  const ctx = await setupTest();

  const imp = buildStubImp({ images: [] });
  const stub = buildStubRunner(imp.handler);

  await writeFile(join(ctx.dir, 'Dockerfile'), 'FROM ghcr.io/zgeoff/imp-base:0.33.0\n');

  const result = await stub.run(['impz', 'image', 'build', ctx.dir, '--name', 'agent-abc1234']);

  expect(result.exitCode).toBe(0);

  expect(imp.images).toStrictEqual([
    { name: 'agent-abc1234', digest: 'imp-build-stub-agent-abc1234' },
  ]);

  expect(imp.builtDockerfiles).toStrictEqual(['FROM ghcr.io/zgeoff/imp-base:0.33.0\n']);
});

test('it fails a build with the scenario’s error and adds no image', async () => {
  const ctx = await setupTest();

  const imp = buildStubImp({ images: [], buildError: 'imp: BUILD_FAILED: the build exited 1' });
  const stub = buildStubRunner(imp.handler);

  await writeFile(join(ctx.dir, 'Dockerfile'), 'FROM scratch\n');

  const result = await stub.run(['impz', 'image', 'build', ctx.dir, '--name', 'agent-abc1234']);

  expect(result).toStrictEqual({
    exitCode: 1,
    stdout: Buffer.from(''),
    stderr: Buffer.from('imp: BUILD_FAILED: the build exited 1\n'),
    timedOut: false,
  });

  expect(imp.images).toStrictEqual([]);
});

test('it answers a build that outlives its timeout as the runner does, and adds no image', async () => {
  const ctx = await setupTest();

  const imp = buildStubImp({ images: [], buildTimesOut: true });
  const stub = buildStubRunner(imp.handler);

  await writeFile(join(ctx.dir, 'Dockerfile'), 'FROM scratch\n');

  const result = await stub.run(['impz', 'image', 'build', ctx.dir, '--name', 'agent-abc1234']);

  expect(result).toStrictEqual({
    exitCode: 143,
    stdout: Buffer.from(''),
    stderr: Buffer.from(''),
    timedOut: true,
  });

  expect(imp.images).toStrictEqual([]);
});

test('it removes an image no imp uses', async () => {
  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'image', 'rm', 'agent-abc1234']);

  expect(result.exitCode).toBe(0);
  expect(imp.images).toStrictEqual([]);
});

test('it refuses to remove a missing image', async () => {
  const imp = buildStubImp({ images: [] });
  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'image', 'rm', 'agent-abc1234']);

  expect(result).toStrictEqual({
    exitCode: 1,
    stdout: Buffer.from(''),
    stderr: Buffer.from('impz: NOT_FOUND: image agent-abc1234 not found\n'),
    timedOut: false,
  });
});

test('it refuses to remove an image an imp uses', async () => {
  const imp = buildStubImp({
    images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }],
    imps: [{ name: 'agent-check-abc1234', image: 'agent-abc1234' }],
  });

  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'image', 'rm', 'agent-abc1234']);

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toBe('impz: CONFLICT: image agent-abc1234 is in use\n');
  expect(imp.images).toStrictEqual([{ name: 'agent-abc1234', digest: 'imp-build-2' }]);
});

test('it creates an imp on an image and prints its name', async () => {
  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'new', 'agent-check-abc1234', '--image', 'agent-abc1234']);

  expect(result.stdout.toString()).toBe('agent-check-abc1234\n');
  expect(imp.imps).toStrictEqual([{ name: 'agent-check-abc1234', image: 'agent-abc1234' }]);
});

test('it refuses an imp on a missing image', async () => {
  const imp = buildStubImp({ images: [] });
  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'new', 'agent-check-abc1234', '--image', 'agent-abc1234']);

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toBe('impz: NOT_FOUND: image agent-abc1234 not found\n');
  expect(imp.imps).toStrictEqual([]);
});

test('it refuses an imp under a taken name', async () => {
  const imp = buildStubImp({
    images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }],
    imps: [{ name: 'agent-check-abc1234', image: 'agent-14d3c9d' }],
  });

  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'new', 'agent-check-abc1234', '--image', 'agent-abc1234']);

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toBe('impz: CONFLICT: imp agent-check-abc1234 already exists\n');
});

test('it lists the imps', async () => {
  const imp = buildStubImp({
    images: [],
    imps: [{ name: 'agent-check-abc1234', image: 'agent-abc1234' }],
  });

  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'ls', '--json']);

  expect(result.stdout.toString()).toBe(
    '[{"name":"agent-check-abc1234","image":"agent-abc1234"}]\n',
  );
});

test('it removes an imp', async () => {
  const imp = buildStubImp({
    images: [],
    imps: [{ name: 'agent-check-abc1234', image: 'agent-abc1234' }],
  });

  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'rm', 'agent-check-abc1234']);

  expect(result.exitCode).toBe(0);
  expect(imp.imps).toStrictEqual([]);
});

test('it refuses to remove a missing imp', async () => {
  const imp = buildStubImp({ images: [] });
  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'rm', 'agent-check-abc1234']);

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toBe('impz: NOT_FOUND: imp agent-check-abc1234 not found\n');
});

test('it fails closed with exit 97 on any other imp call, and leaves other programs alone', async () => {
  const imp = buildStubImp({ images: [] });
  const stub = buildStubRunner(imp.handler);

  const unknown = await stub.run(['impz', 'image', 'ls']);
  const other = await stub.run(['git', 'status']);

  expect(unknown).toStrictEqual({
    exitCode: 97,
    stdout: Buffer.from(''),
    stderr: Buffer.from('unexpected: ["impz","image","ls"]\n'),
    timedOut: false,
  });

  expect(other.stderr.toString()).toBe('unexpected: ["git","status"]\n');
});
