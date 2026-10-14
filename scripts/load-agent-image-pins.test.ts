import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadAgentImagePins } from './load-agent-image-pins.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'load-agent-image-pins-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  return { dir };
}

test('it reads every ARG pin by name, in the file’s order, and nothing else', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.dir, 'Dockerfile'),
    'FROM ubuntu:24.04\nARG GIT_VERSION=1:2.43.0-1ubuntu7.3\nRUN echo ARG FAKE=1\nARG BUN_VERSION=1.4.2\n  ARG INDENTED=1\nARG BUN_SHA256=36368f\n',
  );

  const pins = await loadAgentImagePins(join(ctx.dir, 'Dockerfile'));

  expect(Object.entries(pins)).toStrictEqual([
    ['GIT_VERSION', '1:2.43.0-1ubuntu7.3'],
    ['BUN_VERSION', '1.4.2'],
    ['BUN_SHA256', '36368f'],
  ]);
});

test('it reads the agent image’s own gitleaks pin', async () => {
  const pins = await loadAgentImagePins(join(import.meta.dir, '../images/agent/Dockerfile'));

  expect(pins['GITLEAKS_VERSION']).toMatch(/^\d+\.\d+\.\d+$/u);
  expect(pins['GITLEAKS_SHA256']).toMatch(/^[\da-f]{64}$/u);
});
