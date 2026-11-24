import { join } from 'node:path';
import { recordAgentImageRetention } from './agent-image-retention-state.ts';
import { buildImpArgv } from './imp-cli.ts';
import { parseBuildAgentImageArgs } from './parse-build-agent-image-args.ts';
import { requireFreeAgentImageNames } from './require-free-agent-image-names.ts';
import { resolveMainCommit } from './resolve-main-commit.ts';
import { runAgentImageAliasMove } from './run-agent-image-alias-move.ts';
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

  // more atc config files whose targets boot agent images
  readonly targetConfigs?: readonly string[] | undefined;

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

    if (passed) {
      // impd's image eviction removes an unpinned image that no imp has used for an hour, and a
      // daemon's target boots this one by name
      await runOrExit(options, buildImpArgv(['image', 'pin', run.image]));

      // a passing check makes the image a passing one, whatever a switch recorded before
      await forgetSwitchOnly(options, run.image);

      // The image stays from here on, so an interrupt after this must not remove it.
      dropCleanup();

      await runAgentImageAliasMove(options, run.image);

      // pinned images pile up until the pool fills, so only the newest passing images and the
      // ones that atc targets boot stay pinned
      await unpinOldAgentImages(options, {
        newImage: run.image,
        home: options.home,
        targetFiles: {
          atcConfigs: [
            ...(options.home === undefined ? [] : [join(options.home, '.config/atc/config.json')]),
            ...(options.targetConfigs ?? []),
          ],
          nix: { clone: options.cwd, file: 'nixos/hosts/geoffcloud/configuration.nix' },
        },
      });

      options.printOut(`${run.image} ${built.digest} check passed\n`);

      return 0;
    }

    return await printFailedCheck(options, { ...run, digest: built.digest });
  } finally {
    dropCleanup();
  }
}

async function removeImage(io: Readonly<ScriptIO>, image: string) {
  await runOrExit(io, buildImpArgv(['image', 'rm', image]));
}

async function forgetSwitchOnly(options: Readonly<CreateAgentImageOptions>, image: string) {
  if (options.home === undefined) {
    return;
  }

  try {
    await recordAgentImageRetention(options.home, { passedImage: image });
  } catch (error) {
    options.printErr(
      `could not clear ${image} from the switch-only images: ${error instanceof Error ? error.message : String(error)}\n`,
    );
  }
}

interface FailedCheck {
  readonly image: string;
  readonly digest: string;
  readonly keep: boolean;
}

async function printFailedCheck(io: Readonly<ScriptIO>, result: FailedCheck) {
  if (result.keep) {
    io.printOut(`${result.image} ${result.digest} check failed; kept the image\n`);

    return 1;
  }

  await removeImage(io, result.image);

  io.printOut(`${result.image} check failed; removed the image\n`);

  return 1;
}
