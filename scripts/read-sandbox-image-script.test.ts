import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readSandboxImageScript } from './read-sandbox-image-script.ts';

test('it bundles a script that runs with no node_modules beside it', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'sandbox-image-script-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const script = await readSandboxImageScript();

  await writeFile(join(directory, 'add-sandbox-images.js'), script);

  const child = Bun.spawnSync(['bun', join(directory, 'add-sandbox-images.js')], {
    cwd: directory,
    env: { PATH: process.env['PATH'] ?? '' },
  });

  expect({
    exitCode: child.exitCode,
    stdout: child.stdout.toString(),
    stderr: child.stderr.toString(),
  }).toStrictEqual({
    exitCode: 2,
    stdout: '',
    stderr: 'run-sandbox-image-add: IMPD_URL and NIXIE_SECRETS_FILE must be set\n',
  });
});
