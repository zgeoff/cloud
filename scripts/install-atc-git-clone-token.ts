import { ExitError } from './exit-error.ts';
import type {
  ATCCredentialsContext,
  ATCCredentialsOptions,
} from './load-atc-credentials-context.ts';
import { loadATCCredentialsContext } from './load-atc-credentials-context.ts';
import { pickGitCloneTokenVerdict } from './pick-git-clone-token-verdict.ts';
import { readHostScript } from './read-host-script.ts';
import { runHostCheck, runOnHost } from './run-host-check.ts';
import { runOp } from './run-op.ts';
import { runProcess } from './run-process.ts';
import { withExitCode } from './with-exit-code.ts';

const repoPattern = /^[\w.-]+\/[\w.-]+$/u;

export function installATCGitCloneToken(options: Readonly<ATCCredentialsOptions>): Promise<number> {
  return withExitCode(options.printErr, async () => {
    const repo = options.env['ATC_GIT_CLONE_CHECK_REPO'] ?? '';

    if (!repoPattern.test(repo)) {
      throw new ExitError(
        2,
        'set ATC_GIT_CLONE_CHECK_REPO to the owner/repo that the clone token must read',
      );
    }

    const context = await loadATCCredentialsContext(options);

    const item = options.env['ATC_GIT_CLONE_TOKEN_ITEM'] ?? 'boxxy-github-token';
    const file = `${context.directory}/git-clone-token`;

    context.printOut(
      `\n== atc git clone token: 1Password ${context.vault}/${item} to root@${context.host}:${file}\n`,
    );

    if ((await checkHostFile(context, repo, file)) === 'good') {
      context.printOut('skip: the host file reads the repo\n');

      return 0;
    }

    await writeHostFile(context, item);

    if ((await checkHostFile(context, repo, file)) !== 'good') {
      throw new ExitError(
        1,
        `the token now in ${file} does not read the repo; check the 1Password item's scopes and expiry`,
      );
    }

    context.printOut('ok: the host file reads the repo\n');

    return 0;
  });
}

async function checkHostFile(context: Readonly<ATCCredentialsContext>, repo: string, file: string) {
  const script = await readHostScript('check-atc-git-clone-token.sh');

  const result = await runHostCheck(context, ['bash', '-s', '--', context.directory, repo], {
    stdin: script,
  });

  context.printErr(result.stderr.toString());

  const verdict = pickGitCloneTokenVerdict(result.exitCode);

  if (verdict === 'unchecked') {
    throw new ExitError(
      1,
      `the check of ${file} exited ${result.exitCode} (255 is ssh's); nothing changed`,
    );
  }

  return verdict;
}

async function writeHostFile(context: Readonly<ATCCredentialsContext>, item: string) {
  // op read prints the field and a newline, which the host file holds as it is
  const value = await runOp(context, ['read', `op://${context.vault}/${item}/credential`]);

  if (value.trim() === '') {
    throw new ExitError(1, `the 1Password item ${item} holds no credential; nothing changed`);
  }

  const script = await readHostScript('write-atc-git-clone-token.sh');

  const line = value.endsWith('\n') ? value : `${value}\n`;
  const stdin = Buffer.concat([script, Buffer.from(line)]);

  // the token goes on stdin, so it never reaches the argv that Tailscale SSH logs
  await runOnHost(context, ['bash', '-s', '--', context.directory], stdin);
}

if (import.meta.main) {
  process.exitCode = await installATCGitCloneToken({
    run: runProcess,
    env: process.env,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
