import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runAgentImageBuild } from './run-agent-image-build.ts';
import { buildRealProgramHandler } from './test-utils/build-real-program-handler.ts';
import { buildStubImp } from './test-utils/build-stub-imp.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { createGitOrigin } from './test-utils/create-git-origin.ts';

// a real repository to archive, and a work directory the build writes into
async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'run-agent-image-build-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const repo = await createGitOrigin(dir);

  const work = join(dir, 'work');

  await mkdir(work);

  return { repo, work };
}

test('it builds from the commit’s archive of the image and scripts only, and returns the digest', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await writeFile(join(ctx.repo.seed, 'images/agent/Dockerfile'), 'FROM committed\n');
  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), 'check\n');
  await writeFile(join(ctx.repo.seed, 'README'), 'outside the archive\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);

  await writeFile(join(ctx.repo.seed, 'images/agent/Dockerfile'), 'FROM uncommitted\n');

  const sha = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  const imp = buildStubImp({ images: [] });
  const stub = buildStubRunner(buildRealProgramHandler(['git', 'tar'], ctx.repo.env), imp.handler);
  const printErr = mock<(text: string) => void>();

  const built = await runAgentImageBuild(
    { run: stub.run, printOut: () => {}, printErr },
    {
      image: 'agent-abc1234',
      sha,
      cwd: ctx.repo.seed,
      work: ctx.work,
      timeout: '45m',
      timeoutMs: 2_700_000,
    },
  );

  const check = await readFile(join(ctx.work, 'src/scripts/check-agent-image.ts'), 'utf8');
  const hasReadme = await Bun.file(join(ctx.work, 'src/README')).exists();

  expect(built).toStrictEqual({
    src: join(ctx.work, 'src'),
    digest: 'imp-build-stub-agent-abc1234',
  });

  expect(imp.builtDockerfiles).toStrictEqual(['FROM committed\n']);
  expect(check).toBe('check\n');
  expect(hasReadme).toBe(false);

  expect(printErr.mock.calls).toStrictEqual([
    [`building agent-abc1234 from ${sha}; impz image build shows no progress off a terminal\n`],
  ]);
});
