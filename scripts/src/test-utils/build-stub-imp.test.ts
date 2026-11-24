import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubImp } from './build-stub-imp.ts';
import { buildStubRunner } from './build-stub-runner.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'build-stub-imp-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it lists each image with the name, ref and digest the scripts read', async () => {
  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'image', 'ls', '--json']);

  expect(result.stdout.toString()).toBe(
    '[{"name":"agent-abc1234","ref":"imp/agent-abc1234:latest","digest":"imp-build-2","createdAt":"2026-01-01T00:00:00.000Z","pinned":false,"aliases":[]}]\n',
  );
});

test('it builds an image from a folder and reads the folder’s Dockerfile when the build runs', async () => {
  const ctx = await setupTest();

  const imp = buildStubImp({ images: [] });
  const stub = buildStubRunner(imp.handler);

  await writeFile(join(ctx.directory, 'Dockerfile'), 'FROM ghcr.io/zgeoff/imp-base:0.33.0\n');

  const result = await stub.run([
    'impz',
    'image',
    'build',
    ctx.directory,
    '--name',
    'agent-abc1234',
  ]);

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

  await writeFile(join(ctx.directory, 'Dockerfile'), 'FROM scratch\n');

  const result = await stub.run([
    'impz',
    'image',
    'build',
    ctx.directory,
    '--name',
    'agent-abc1234',
  ]);

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

  await writeFile(join(ctx.directory, 'Dockerfile'), 'FROM scratch\n');

  const result = await stub.run([
    'impz',
    'image',
    'build',
    ctx.directory,
    '--name',
    'agent-abc1234',
  ]);

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

test('it pins an image and leaves the other images alone', async () => {
  const imp = buildStubImp({
    images: [
      { name: 'agent-abc1234', digest: 'imp-build-2' },
      { name: 'agent-def5678', digest: 'imp-build-3' },
    ],
  });

  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'image', 'pin', 'agent-abc1234']);

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from(''),
    stderr: Buffer.from(''),
    timedOut: false,
  });

  expect(imp.images).toStrictEqual([
    { name: 'agent-abc1234', digest: 'imp-build-2', isPinned: true },
    { name: 'agent-def5678', digest: 'imp-build-3' },
  ]);
});

test('it refuses to pin a missing image', async () => {
  const imp = buildStubImp({ images: [] });
  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'image', 'pin', 'agent-abc1234']);

  expect(result).toStrictEqual({
    exitCode: 1,
    stdout: Buffer.from(''),
    stderr: Buffer.from('impz: NOT_FOUND: image agent-abc1234 not found\n'),
    timedOut: false,
  });
});

test('it creates an imp on an image and prints its name', async () => {
  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler);

  const result = await stub.run([
    'impz',
    'new',
    'agent-check-abc1234',
    '--image',
    'agent-abc1234',
    '--memory',
    '1024',
    '--max-memory',
    '2048',
  ]);

  expect(result.stdout.toString()).toBe('agent-check-abc1234\n');
  expect(imp.imps).toStrictEqual([{ name: 'agent-check-abc1234', image: 'agent-abc1234' }]);
});

test('it refuses an imp on a missing image', async () => {
  const imp = buildStubImp({ images: [] });
  const stub = buildStubRunner(imp.handler);

  const result = await stub.run([
    'impz',
    'new',
    'agent-check-abc1234',
    '--image',
    'agent-abc1234',
    '--memory',
    '1024',
    '--max-memory',
    '2048',
  ]);

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

  const result = await stub.run([
    'impz',
    'new',
    'agent-check-abc1234',
    '--image',
    'agent-abc1234',
    '--memory',
    '1024',
    '--max-memory',
    '2048',
  ]);

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

test('it unpins a pinned image and lists it as unpinned', async () => {
  const imp = buildStubImp({
    images: [{ name: 'agent-abc1234', digest: 'imp-build-2', isPinned: true }],
  });

  const stub = buildStubRunner(imp.handler);

  const result = await stub.run(['impz', 'image', 'unpin', 'agent-abc1234']);

  expect(result.exitCode).toBe(0);

  expect(imp.images).toStrictEqual([
    { name: 'agent-abc1234', digest: 'imp-build-2', isPinned: false },
  ]);
});

test('it moves an alias to one image, and lists it on that image only', async () => {
  const imp = buildStubImp({
    images: [
      { name: 'agent-aaa1111', digest: 'imp-build-1', aliases: ['agent'] },
      { name: 'agent-bbb2222', digest: 'imp-build-2' },
    ],
  });

  const stub = buildStubRunner(imp.handler);

  const moved = await stub.run(['impz', 'image', 'alias', 'agent', 'agent-bbb2222']);
  const missing = await stub.run(['impz', 'image', 'alias', 'agent', 'agent-absent']);

  expect(moved.exitCode).toBe(0);
  expect(missing.exitCode).toBe(1);
  expect(imp.images.map((image) => image.aliases)).toStrictEqual([[], ['agent']]);
});

test('it reports the imageAliases feature in info', async () => {
  const stub = buildStubRunner(buildStubImp({ images: [], hasImageAliases: false }).handler);

  const result = await stub.run(['impz', 'info', '--json']);

  expect(result.stdout.toString()).toBe('{"features":{"imageAliases":false}}\n');
});

test('it answers info and image alias with the scenario answers in place of its own', async () => {
  const stub = buildStubRunner(
    buildStubImp({
      images: [{ name: 'agent-aaa1111', digest: 'imp-build-1' }],
      infoAnswer: { exitCode: 2, stderr: 'impz: unknown command inspect\n' },
      aliasAnswer: { exitCode: 143, timedOut: true },
    }).handler,
  );

  const info = await stub.run(['impz', 'info', '--json']);
  const alias = await stub.run(['impz', 'image', 'alias', 'agent', 'agent-aaa1111']);

  expect([info.exitCode, info.stderr.toString()]).toStrictEqual([
    2,
    'impz: unknown command inspect\n',
  ]);

  expect([alias.exitCode, alias.timedOut]).toStrictEqual([143, true]);
});
