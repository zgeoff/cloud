import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readWorkerBundle } from './read-worker-bundle.ts';

test('it bundles an entry and its imports into one module that runs on its own', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'greet.ts'),
    "export const greet = (name: string): string => 'hi ' + name;\n",
  );

  await writeFile(
    join(ctx.directory, 'index.ts'),
    "import { greet } from './greet.ts';\nconsole.log(greet('sam'));\n",
  );

  await mkdir(join(ctx.directory, 'out'));

  const bundle = await readWorkerBundle(join(ctx.directory, 'index.ts'));

  await writeFile(join(ctx.directory, 'out', 'index.js'), bundle);

  const run = Bun.spawnSync([process.execPath, join(ctx.directory, 'out', 'index.js')], {
    cwd: join(ctx.directory, 'out'),
  });

  expect({
    exitCode: run.exitCode,
    stdout: run.stdout.toString(),
    stderr: run.stderr.toString(),
  }).toStrictEqual({
    exitCode: 0,
    stdout: 'hi sam\n',
    stderr: '',
  });
});

test('it fails with the bundler reason when an import cannot be resolved', async () => {
  const ctx = await setupTest();

  const entrypoint = join(ctx.directory, 'index.ts');

  await writeFile(entrypoint, "import { greet } from './missing.ts';\nexport default greet;\n");

  expect(readWorkerBundle(entrypoint)).rejects.toThrowWithMessage(
    Error,
    `bundle of ${entrypoint} failed: Could not resolve: "./missing.ts"`,
  );
});

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'worker-bundle-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}
