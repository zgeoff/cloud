// Moves the `agent` alias to an image that already passed its check, such as one that an impd
// without image aliases left behind. Takes the image's name. Needs an imp CLI that calls the
// geoffcloud host with a manage-scope token.
import { ExitError } from './exit-error.ts';
import { runAgentImageAliasMove } from './run-agent-image-alias-move.ts';
import { runProcess } from './run-process.ts';
import { withExitCode } from './with-exit-code.ts';

function printOut(text: string) {
  process.stdout.write(text);
}

function printErr(text: string) {
  process.stderr.write(text);
}

const image = process.argv[2] ?? '';

process.exitCode = await withExitCode(printErr, async () => {
  if (process.argv.length !== 3 || !image.startsWith('agent-')) {
    throw new ExitError(2, 'usage: bun scripts/promote-agent-image.ts agent-<short sha>');
  }

  const outcome = await runAgentImageAliasMove({ run: runProcess, printOut, printErr }, image);

  printOut(`${image} alias ${outcome}\n`);

  return 0;
});
