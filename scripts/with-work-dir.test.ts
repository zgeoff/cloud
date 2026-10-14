import { expect, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { withWorkDir } from './with-work-dir.ts';

test('it runs the body in a fresh directory under the temp directory and removes it after', async () => {
  const seen: string[] = [];

  const result = await withWorkDir(
    { registerCleanup: () => () => {} },
    'with-work-dir-',
    async (work) => {
      seen.push(work);

      await writeFile(join(work, 'src.tar'), 'archive');

      return 'built';
    },
  );

  const [work = ''] = seen;

  expect(result).toBe('built');
  expect(work).toStartWith(join(tmpdir(), 'with-work-dir-'));
  expect(existsSync(work)).toBe(false);
});

test('it removes the directory when the body throws', async () => {
  const seen: string[] = [];

  const running = withWorkDir({ registerCleanup: () => () => {} }, 'with-work-dir-', (work) => {
    seen.push(work);

    return Promise.reject(new Error('the build failed'));
  });

  expect(running).rejects.toThrowWithMessage(Error, 'the build failed');

  await running.catch(() => {});

  expect(existsSync(seen[0] ?? '')).toBe(false);
});

test('it registers the removal before mkdtemp ends, and the removal waits for the directory', async () => {
  const steps: (() => unknown)[] = [];
  const seen: string[] = [];

  // the body never ends, as a script's own steps park after an interrupt
  void withWorkDir(
    {
      registerCleanup: (step) => {
        steps.push(() => step({ run: buildStubRunner().run, printOut() {}, printErr() {} }));

        return () => {};
      },
    },
    'with-work-dir-',
    (work) => {
      seen.push(work);

      return Promise.withResolvers<never>().promise;
    },
  );

  const registeredAtCall = steps.length;

  await Promise.all(steps.map((step) => step()));

  const [work = ''] = seen;

  expect(registeredAtCall).toBe(1);
  expect(work).toStartWith(join(tmpdir(), 'with-work-dir-'));
  expect(existsSync(work)).toBe(false);
});

test('it leaves the directory to an interrupt while the body runs, and drops that step after', async () => {
  const steps = new Set<() => unknown>();

  const removedByInterrupt: boolean[] = [];

  await withWorkDir(
    {
      registerCleanup: (step) => {
        const runStep = () => step({ run: buildStubRunner().run, printOut() {}, printErr() {} });

        steps.add(runStep);

        return () => {
          steps.delete(runStep);
        };
      },
    },
    'with-work-dir-',
    async (work) => {
      await Promise.all([...steps].map((step) => step()));

      removedByInterrupt.push(!existsSync(work));
    },
  );

  expect(removedByInterrupt).toStrictEqual([true]);
  expect(steps.size).toBe(0);
});
