import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runAgentImageCheck } from './run-agent-image-check.ts';
import { buildStubCheckAgentImage } from './test-utils/build-stub-check-agent-image.ts';
import { buildStubImp } from './test-utils/build-stub-imp.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

// a work directory with the extracted source's scripts folder
async function setupTest() {
  const work = await mkdtemp(join(tmpdir(), 'run-agent-image-check-'));

  onTestFinished(() => rm(work, { recursive: true, force: true }));

  await mkdir(join(work, 'src/scripts'), { recursive: true });

  return { work, source: join(work, 'src') };
}

test('it runs the source’s check on a fresh imp, with a long timeout, and removes the imp', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.source, 'scripts/check-agent-image.ts'), '');

  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler, buildStubCheckAgentImage(0));
  const printErr = mock<(text: string) => void>();

  const passed = await runAgentImageCheck(
    { run: stub.run, printOut: () => {}, printErr, registerCleanup: () => () => {} },
    { image: 'agent-abc1234', check: 'agent-check-abc1234', source: ctx.source, work: ctx.work },
  );

  expect(passed).toBe(true);

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    ['impz', 'new', 'agent-check-abc1234', '--image', 'agent-abc1234'],
    ['bun', join(ctx.source, 'scripts/check-agent-image.ts'), '--imp', 'agent-check-abc1234'],
    ['impz', 'rm', 'agent-check-abc1234'],
  ]);

  expect(stub.calls[1]?.options).toStrictEqual({
    cwd: ctx.work,
    timeoutMs: 1_800_000,
    env: { ...process.env, PATH: `${join(ctx.work, 'imp-shim')}:${process.env['PATH'] ?? ''}` },
  });

  expect(printErr.mock.calls).toStrictEqual([['agent-check-abc1234\n'], ['== 0 failed\n']]);
});

test('it hands a pre-rename check’s imp calls to impz through the shim on its PATH', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.source, 'scripts/check-agent-image.sh'), '');

  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler, buildStubCheckAgentImage(0));

  await runAgentImageCheck(
    { run: stub.run, printOut: () => {}, printErr: () => {}, registerCleanup: () => () => {} },
    { image: 'agent-abc1234', check: 'agent-check-abc1234', source: ctx.source, work: ctx.work },
  );

  const bin = join(ctx.work, 'stub-bin');

  await mkdir(bin);
  await writeFile(join(bin, 'impz'), '#!/bin/sh\necho "impz $*"\n', { mode: 0o755 });

  const result = Bun.spawnSync([join(ctx.work, 'imp-shim', 'imp'), 'cp', 'dir', 'box:/x'], {
    env: { PATH: `${bin}:/usr/bin:/bin` },
  });

  expect(result.stdout.toString()).toBe('impz cp dir box:/x\n');
});

test('it reports a failed check after it removes the imp', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.source, 'scripts/check-agent-image.sh'), '');

  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler, buildStubCheckAgentImage(3));

  const passed = await runAgentImageCheck(
    { run: stub.run, printOut: () => {}, printErr: () => {}, registerCleanup: () => () => {} },
    { image: 'agent-abc1234', check: 'agent-check-abc1234', source: ctx.source, work: ctx.work },
  );

  expect(passed).toBe(false);
  expect(stub.calls[1]?.argv[0]).toBe('bash');
  expect(imp.imps).toStrictEqual([]);
});

test('it leaves the imp’s removal to an interrupt from impz new on, and drops that step after', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.source, 'scripts/check-agent-image.ts'), '');

  // each registered step, bound to a runner that records what an interrupt would run
  const steps = new Set<() => unknown>();

  const interrupt = buildStubRunner(() => ({}));
  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });

  const stub = buildStubRunner(
    async (call) => {
      if (call.argv[1] === 'new') {
        await Promise.all([...steps].map((step) => step()));
      }
    },
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  const passed = await runAgentImageCheck(
    {
      run: stub.run,
      printOut: () => {},
      printErr: () => {},
      registerCleanup: (step) => {
        const runStep = () => step({ run: interrupt.run, printOut() {}, printErr() {} });

        steps.add(runStep);

        return () => {
          steps.delete(runStep);
        };
      },
    },
    { image: 'agent-abc1234', check: 'agent-check-abc1234', source: ctx.source, work: ctx.work },
  );

  expect(passed).toBe(true);

  expect(interrupt.calls.map((call) => call.argv)).toStrictEqual([
    ['impz', 'rm', 'agent-check-abc1234'],
  ]);

  expect(steps.size).toBe(0);
});

test('it reports a check that outlives its timeout as failed', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.source, 'scripts/check-agent-image.ts'), '');

  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler, () => ({ exitCode: 0, timedOut: true }));

  const passed = await runAgentImageCheck(
    { run: stub.run, printOut: () => {}, printErr: () => {}, registerCleanup: () => () => {} },
    { image: 'agent-abc1234', check: 'agent-check-abc1234', source: ctx.source, work: ctx.work },
  );

  expect(passed).toBe(false);
  expect(imp.imps).toStrictEqual([]);
});
