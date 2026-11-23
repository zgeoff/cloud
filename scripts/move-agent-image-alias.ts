import { agentImageAlias } from './constants.ts';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';
import { buildImpArgv, loadImpJSON } from './imp-cli.ts';
import type { ScriptIO } from './run-or-exit.ts';

// Moves the `agent` alias to an image that passed its check. An impd without image aliases gets a
// warning and no move, because the release that adds them can deploy after this script runs. Any
// other failure exits 1, and the image stays pinned.
export async function moveAgentImageAlias(io: Readonly<ScriptIO>, image: string): Promise<void> {
  const info = await loadImpJSON(io, ['info']);

  if (findJSONField(findJSONField(info, 'features'), 'imageAliases') !== true) {
    skip(io, image, 'impd lacks the imageAliases feature');

    return;
  }

  const result = await io.run(buildImpArgv(['image', 'alias', agentImageAlias, image]));

  if (result.exitCode === 0 && !result.timedOut) {
    io.printErr(`moved the ${agentImageAlias} alias to ${image}\n`);

    return;
  }

  const stderr = result.stderr.toString().trim();

  if (/unknown command/iu.test(stderr)) {
    skip(io, image, 'impz does not know image alias');

    return;
  }

  throw new ExitError(
    1,
    `could not move the ${agentImageAlias} alias to ${image}; the image stays pinned: ` +
      `${result.timedOut ? 'timed out' : stderr}`,
  );
}

function skip(io: Readonly<ScriptIO>, image: string, reason: string) {
  io.printErr(
    `warning: ${reason}, so the ${agentImageAlias} alias stays where it was and does not move to ` +
      `${image}\n`,
  );
}
