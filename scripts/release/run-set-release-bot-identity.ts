import { runProcess } from '../run-process.ts';
import { runChecked } from './run-checked.ts';
import { runGitSteps } from './run-git-steps.ts';
import type { BumpContext } from './types.ts';

export async function runSetReleaseBotIdentity(
  context: BumpContext,
  args: readonly string[],
): Promise<number> {
  const [slug = ''] = args;

  if (args.length !== 1 || slug === '') {
    context.printErr('usage: run-set-release-bot-identity.ts <app slug>\n');

    return 2;
  }

  const id = await runChecked(context.run, ['gh', 'api', `users/${slug}%5Bbot%5D`, '--jq', '.id'], {
    cwd: context.cwd,
    env: context.env,
  });

  const set =
    id instanceof Error
      ? id
      : await runGitSteps(context, [
          ['config', 'user.name', `${slug}[bot]`],
          ['config', 'user.email', `${id.trim()}+${slug}[bot]@users.noreply.github.com`],
        ]);

  if (set instanceof Error) {
    context.printErr(`${set.message}\n`);

    return 1;
  }

  return 0;
}

if (import.meta.main) {
  process.exitCode = await runSetReleaseBotIdentity(
    {
      cwd: process.cwd(),
      env: process.env,
      run: runProcess,
      printOut: (text) => {
        process.stdout.write(text);
      },
      printErr: (text) => {
        process.stderr.write(text);
      },
    },
    process.argv.slice(2),
  );
}
