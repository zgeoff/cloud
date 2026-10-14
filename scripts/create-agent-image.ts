import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseBuildAgentImageArgs } from './parse-build-agent-image-args.ts';
import { requireFreeAgentImageNames } from './require-free-agent-image-names.ts';
import { resolveMainCommit } from './resolve-main-commit.ts';
import { runAgentImageBuild } from './run-agent-image-build.ts';
import { runAgentImageCheck } from './run-agent-image-check.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import { withExitCode } from './with-exit-code.ts';

export interface CreateAgentImageOptions extends ScriptIO {
  // `[--keep] [<commit on main>]`
  readonly args: readonly string[];

  // the zgeoff/cloud clone that git runs in
  readonly cwd: string;

  // AGENT_IMAGE_BUILD_TIMEOUT, a `timeout` duration, when set
  readonly buildTimeout?: string;
}

// Builds images/agent for one commit on origin's main as agent-<short sha>, then checks it on a
// fresh imp with that commit's check. A failed check removes the image unless --keep is given,
// and every failure exits 1. The last line on stdout names the image, its digest and the result.
export function createAgentImage(options: Readonly<CreateAgentImageOptions>): Promise<number> {
  return withExitCode(options.printErr, async () => {
    const request = parseBuildAgentImageArgs(options.args, options.buildTimeout ?? '45m');

    const commit = await resolveMainCommit(options, options.cwd, request.commit);

    const names = { image: `agent-${commit.short}`, check: `agent-check-${commit.short}` };

    await requireFreeAgentImageNames(options, names);

    const work = await mkdtemp(join(tmpdir(), 'agent-image-build-'));

    try {
      return await runBuildAndCheck(options, { ...request, ...names, sha: commit.sha, work });
    } finally {
      await rm(work, { recursive: true, force: true });
    }
  });
}

interface AgentImageRun {
  readonly image: string;
  readonly check: string;
  readonly sha: string;
  readonly work: string;
  readonly keep: boolean;
  readonly timeout: string;
  readonly timeoutMs: number;
}

async function runBuildAndCheck(options: Readonly<CreateAgentImageOptions>, run: AgentImageRun) {
  const built = await runAgentImageBuild(options, { ...run, cwd: options.cwd });

  options.printErr(`checking ${run.image} on a fresh imp, ${run.check}\n`);

  const passed = await runAgentImageCheck(options, { ...run, src: built.src });

  return printCheckResult(options, { ...run, digest: built.digest, passed });
}

interface CheckResult {
  readonly image: string;
  readonly digest: string;
  readonly keep: boolean;
  readonly passed: boolean;
}

// prints the last line, after removing an image whose check failed unless --keep keeps it
async function printCheckResult(io: Readonly<ScriptIO>, result: CheckResult) {
  if (result.passed) {
    io.printOut(`${result.image} ${result.digest} check passed\n`);

    return 0;
  }

  if (result.keep) {
    io.printOut(`${result.image} ${result.digest} check failed; kept the image\n`);

    return 1;
  }

  await runOrExit(io, ['imp', 'image', 'rm', result.image]);

  io.printOut(`${result.image} check failed; removed the image\n`);

  return 1;
}
