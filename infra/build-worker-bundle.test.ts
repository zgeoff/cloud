import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildWorkerBundle } from './build-worker-bundle.ts';

test('it bundles an entry and its imports into one module that runs on its own', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.dir, 'greet.ts'),
    "export const greet = (name: string): string => 'hi ' + name;\n",
  );

  await writeFile(
    join(ctx.dir, 'index.ts'),
    "import { greet } from './greet.ts';\nconsole.log(greet('geoff'));\n",
  );

  await mkdir(join(ctx.dir, 'out'));

  const bundle = await buildWorkerBundle(join(ctx.dir, 'index.ts'));

  await writeFile(join(ctx.dir, 'out', 'index.js'), bundle);

  const run = Bun.spawnSync([process.execPath, join(ctx.dir, 'out', 'index.js')], {
    cwd: join(ctx.dir, 'out'),
  });

  expect({
    exitCode: run.exitCode,
    stdout: run.stdout.toString(),
    stderr: run.stderr.toString(),
  }).toStrictEqual({
    exitCode: 0,
    stdout: 'hi geoff\n',
    stderr: '',
  });
});

test('it fails with the bundler reason when an import cannot be resolved', async () => {
  const ctx = await setupTest();

  const entrypoint = join(ctx.dir, 'index.ts');

  await writeFile(entrypoint, "import { greet } from './missing.ts';\nexport default greet;\n");

  expect(buildWorkerBundle(entrypoint)).rejects.toThrowWithMessage(
    Error,
    `bundle of ${entrypoint} failed: Could not resolve: "./missing.ts"`,
  );
});

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'worker-bundle-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  return { dir };
}
