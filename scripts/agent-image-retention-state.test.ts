import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  readAgentImageRetentionState,
  recordAgentImageRetention,
} from './agent-image-retention-state.ts';

async function setupTest() {
  const home = await mkdtemp(join(tmpdir(), 'agent-image-retention-state-'));

  onTestFinished(() => rm(home, { recursive: true, force: true }));

  return { home };
}

test('it holds nothing for a home that no script wrote to', async () => {
  const ctx = await setupTest();
  const state = await readAgentImageRetentionState(ctx.home);

  expect(state).toStrictEqual({ configs: [], switchOnlyImages: [] });
});

test('it adds each config and switch-only image once, and clears an image that passed', async () => {
  const ctx = await setupTest();

  await recordAgentImageRetention(ctx.home, { config: '/a.json', switchOnlyImage: 'agent-1' });
  await recordAgentImageRetention(ctx.home, { config: '/a.json', switchOnlyImage: 'agent-2' });
  await recordAgentImageRetention(ctx.home, { passedImage: 'agent-1' });

  const state = await readAgentImageRetentionState(ctx.home);

  expect(state).toStrictEqual({ configs: ['/a.json'], switchOnlyImages: ['agent-2'] });
});
