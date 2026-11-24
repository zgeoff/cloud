import { match } from 'ts-pattern';
import { agentImageAlias } from './constants.ts';
import { ExitError } from './exit-error.ts';
import { buildImpArgv } from './imp-cli.ts';
import { pickAliasVerdictForInfo } from './pick-alias-verdict-for-info.ts';
import { pickAliasVerdictForMove } from './pick-alias-verdict-for-move.ts';
import type { ScriptIO } from './run-or-exit.ts';
import type { AliasVerdict, ImpAnswer } from './types.ts';

// Moves the `agent` alias to an image that passed its check. An impd without image aliases gets a
// warning and no move, because the release that adds them can deploy after this script runs. Any
// other failure exits 1, and the image stays pinned.
export async function runAgentImageAliasMove(
  io: Readonly<ScriptIO>,
  image: string,
): Promise<'moved' | 'skipped'> {
  const info = await runImp(io, ['info', '--json']);

  const infoVerdict = pickAliasVerdictForInfo(info);

  if (infoVerdict.kind !== 'ok') {
    return finish(io, image, infoVerdict);
  }

  const move = await runImp(io, ['image', 'alias', agentImageAlias, image]);

  return finish(io, image, pickAliasVerdictForMove(move));
}

async function runImp(io: Readonly<ScriptIO>, args: readonly string[]): Promise<ImpAnswer> {
  const result = await io.run(buildImpArgv(args));

  return {
    exitCode: result.exitCode,
    timedOut: result.timedOut,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  };
}

function finish(io: Readonly<ScriptIO>, image: string, verdict: AliasVerdict): 'moved' | 'skipped' {
  return match(verdict)
    .with({ kind: 'ok' }, () => {
      io.printErr(`moved the ${agentImageAlias} alias to ${image}\n`);

      return 'moved' as const;
    })
    .with({ kind: 'skip' }, (step) => {
      io.printErr(
        `warning: ${step.reason}, so the ${agentImageAlias} alias stays where it was and does not move ` +
          `to ${image}\n`,
      );

      return 'skipped' as const;
    })
    .with({ kind: 'fail' }, (step) => {
      throw new ExitError(
        1,
        `could not move the ${agentImageAlias} alias to ${image}; the image stays pinned: ${step.reason}`,
      );
    })
    .exhaustive();
}
