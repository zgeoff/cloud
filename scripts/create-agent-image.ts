import { join } from 'node:path';
import { buildImpArgv } from './imp-cli.ts';
import type { TargetImageFiles } from './load-target-agent-images.ts';
import { parseBuildAgentImageArgs } from './parse-build-agent-image-args.ts';
import { requireFreeAgentImageNames } from './require-free-agent-image-names.ts';
import { resolveMainCommit } from './resolve-main-commit.ts';
import { runAgentImageBuild } from './run-agent-image-build.ts';
import { runAgentImageCheck } from './run-agent-image-check.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import type { InterruptibleIO } from './subscribe-to-interrupts.ts';
import { unpinOldAgentImages } from './unpin-old-agent-images.ts';
import { withExitCode } from './with-exit-code.ts';
import { withWorkDir } from './with-work-dir.ts';

export interface CreateAgentImageOptions extends InterruptibleIO {
  readonly args: readonly string[];

  readonly cwd: string;

  // the home folder whose atc config names the images its targets boot
  readonly home?: string | undefined;

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

    return await printCheckResult(options, {
      ...run,
      digest: built.digest,
      passed,
      targetFiles: {
        atcConfigs:
          options.home === undefined ? [] : [join(options.home, '.config/atc/config.json')],
        nixFiles: [join(options.cwd, 'nixos/hosts/geoffcloud/configuration.nix')],
      },
    });
  } finally {
    dropCleanup();
  }
}

async function removeImage(io: Readonly<ScriptIO>, image: string) {
  await runOrExit(io, buildImpArgv(['image', 'rm', image]));
}

interface CheckResult {
  readonly image: string;
  readonly digest: string;
  readonly keep: boolean;
  readonly passed: boolean;
  readonly targetFiles: TargetImageFiles;
}

async function printCheckResult(io: Readonly<ScriptIO>, result: CheckResult) {
  if (result.passed) {
    // impd's image eviction removes an unpinned image that no imp has used for an hour, and a
    // daemon's target boots this one by name
    await runOrExit(io, buildImpArgv(['image', 'pin', result.image]));

    // pinned images pile up until the pool fills, so only the newest passing images and the ones
    // that atc targets boot stay pinned
    await unpinOldAgentImages(io, { newImage: result.image, targetFiles: result.targetFiles });

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
