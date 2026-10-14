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

  return { work, src: join(work, 'src') };
}

test('it runs the source’s check on a fresh imp, with a long timeout, and removes the imp', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.src, 'scripts/check-agent-image.ts'), '');

  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler, buildStubCheckAgentImage(0));
  const printErr = mock();

  const passed = await runAgentImageCheck(
    { run: stub.run, printOut: () => {}, printErr },
    { image: 'agent-abc1234', check: 'agent-check-abc1234', src: ctx.src, work: ctx.work },
  );

  expect(passed).toBe(true);

  expect(stub.calls.map((call) => call.argv)).toStrictEqual([
    ['imp', 'new', 'agent-check-abc1234', '--image', 'agent-abc1234'],
    ['bun', join(ctx.src, 'scripts/check-agent-image.ts'), '--imp', 'agent-check-abc1234'],
    ['imp', 'rm', 'agent-check-abc1234'],
  ]);

  expect(stub.calls[1]?.options).toStrictEqual({ cwd: ctx.work, timeoutMs: 1_800_000 });
  expect(printErr.mock.calls).toStrictEqual([['agent-check-abc1234\n'], ['== 0 failed\n']]);
});

test('it reports a failed check after it removes the imp', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.src, 'scripts/check-agent-image.sh'), '');

  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler, buildStubCheckAgentImage(3));

  const passed = await runAgentImageCheck(
    { run: stub.run, printOut: () => {}, printErr: () => {} },
    { image: 'agent-abc1234', check: 'agent-check-abc1234', src: ctx.src, work: ctx.work },
  );

  expect(passed).toBe(false);
  expect(stub.calls[1]?.argv[0]).toBe('bash');
  expect(imp.imps).toStrictEqual([]);
});

test('it reports a check that outlives its timeout as failed', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.src, 'scripts/check-agent-image.ts'), '');

  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler, () => ({ exitCode: 0, timedOut: true }));

  const passed = await runAgentImageCheck(
    { run: stub.run, printOut: () => {}, printErr: () => {} },
    { image: 'agent-abc1234', check: 'agent-check-abc1234', src: ctx.src, work: ctx.work },
  );

  expect(passed).toBe(false);
  expect(imp.imps).toStrictEqual([]);
});
