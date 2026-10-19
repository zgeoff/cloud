import { buildImpArgv } from './imp-cli.ts';
import { parseBuildAgentImageArgs } from './parse-build-agent-image-args.ts';
import { requireFreeAgentImageNames } from './require-free-agent-image-names.ts';
import { resolveMainCommit } from './resolve-main-commit.ts';
import { runAgentImageBuild } from './run-agent-image-build.ts';
import { runAgentImageCheck } from './run-agent-image-check.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import type { InterruptibleIO } from './subscribe-to-interrupts.ts';
import { withExitCode } from './with-exit-code.ts';
import { withWorkDir } from './with-work-dir.ts';

export interface CreateAgentImageOptions extends InterruptibleIO {
  readonly args: readonly string[];

  readonly cwd: string;

  readonly buildTimeout?: string | undefined;
}

export function createAgentImage(options: Readonly<CreateAgentImageOptions>): Promise<number> {
  return withExitCode(options.printErr, async () => {
    const request = parseBuildAgentImageArgs(options.args, options.buildTimeout ?? '45m');

    const commit = await resolveMainCommit(options, options.cwd, request.commit);

    const names = { image: `agent-${commit.short}`, check: `agent-check-${commit.short}` };

    await requireFreeAgentImageNames(options, names);

    return withWorkDir(options, 'agent-image-build-', (work) =>
      runBuildAndCheck(options, { ...request, ...names, sha: commit.sha, work }),
    );
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
  // An interrupt leaves the image unchecked, so it goes as a failed check's image goes. The step
  // comes before the build, since the image exists before the build call returns.
  const dropCleanup = run.keep
    ? () => {}
    : options.registerCleanup((io) => removeImage(io, run.image));

  try {
    const built = await runAgentImageBuild(options, { ...run, cwd: options.cwd });

    options.printErr(`checking ${run.image} on a fresh imp, ${run.check}\n`);

    const passed = await runAgentImageCheck(options, { ...run, source: built.source });

    return await printCheckResult(options, { ...run, digest: built.digest, passed });
  } finally {
    dropCleanup();
  }
}

interface CheckResult {
  readonly image: string;
  readonly digest: string;
  readonly keep: boolean;
  readonly passed: boolean;
}

async function printCheckResult(io: Readonly<ScriptIO>, result: CheckResult) {
  if (result.passed) {
    io.printOut(`${result.image} ${result.digest} check passed\n`);

    return 0;
  }

  if (result.keep) {
    io.printOut(`${result.image} ${result.digest} check failed; kept the image\n`);

    return 1;
  }

  await removeImage(io, result.image);

  io.printOut(`${result.image} check failed; removed the image\n`);

  return 1;
}

async function removeImage(io: Readonly<ScriptIO>, image: string) {
  await runOrExit(io, buildImpArgv(['image', 'rm', image]));
}
