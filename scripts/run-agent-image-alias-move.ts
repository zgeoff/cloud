import { buildAliasMoveReport } from './build-alias-move-report.ts';
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
    return reportMove(io, image, infoVerdict);
  }

  const move = await runImp(io, ['image', 'alias', agentImageAlias, image]);

  return reportMove(io, image, pickAliasVerdictForMove(move));
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

function reportMove(
  io: Readonly<ScriptIO>,
  image: string,
  verdict: Readonly<AliasVerdict>,
): 'moved' | 'skipped' {
  const report = buildAliasMoveReport(verdict, image);

  if (report.outcome === 'failed') {
    throw new ExitError(1, report.message);
  }

  io.printErr(report.message);

  return report.outcome;
}
