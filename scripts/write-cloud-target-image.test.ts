// a test arranges a leftover temp file beside the config, so its body is long
/* oxlint-disable max-statements */
import { expect, onTestFinished, test } from 'bun:test';
import { chmod, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { writeCloudTargetImage } from './write-cloud-target-image.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'write-cloud-target-image-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  return { dir };
}

test('it names the backup for the UTC second and the image, and keeps the config’s mode on it', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.dir, 'config.json'), '{"targets":{"cloud":{}}}');
  await chmod(join(ctx.dir, 'config.json'), 0o640);

  const backup = await writeCloudTargetImage({
    config: join(ctx.dir, 'config.json'),
    image: 'agent-abc1234',
    guestATC: '/usr/local/bin/atc',
    now: new Date('2026-01-02T03:04:05.999Z'),
  });

  const info = await stat(backup);

  expect(backup).toBe(join(ctx.dir, 'config.json.bak-20260102T030405Z-pre-agent-abc1234'));
  expect(info.mode & 0o777).toBe(0o640);
});

test('it replaces the config with one readable by its owner only, and leaves no temp file', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.dir, 'config.json'), '{"targets":{"cloud":{"image":"agent-14d3c9d"}}}');
  await chmod(join(ctx.dir, 'config.json'), 0o644);
  await writeFile(join(ctx.dir, 'config.json.new'), 'left by an earlier run');
  await chmod(join(ctx.dir, 'config.json.new'), 0o666);

  await writeCloudTargetImage({
    config: join(ctx.dir, 'config.json'),
    image: 'agent-abc1234',
    guestATC: '/usr/local/bin/atc',
    now: new Date('2026-10-10T05:06:07Z'),
  });

  const info = await stat(join(ctx.dir, 'config.json'));
  const text = await readFile(join(ctx.dir, 'config.json'), 'utf8');
  const files = await readdir(ctx.dir);

  expect(info.mode & 0o777).toBe(0o600);

  expect(text).toBe(
    '{\n  "targets": {\n    "cloud": {\n      "image": "agent-abc1234",\n      "guestATC": "/usr/local/bin/atc"\n    }\n  }\n}\n',
  );

  expect(files.toSorted()).toStrictEqual([
    'config.json',
    'config.json.bak-20261010T050607Z-pre-agent-abc1234',
  ]);
});
