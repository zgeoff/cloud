// Opens or updates the pull request that pins an atc release in the agent image, from the root of
// a zgeoff/cloud clone with gh signed in. atc's release job runs it through open-atc-pin-pr.sh
// after each release, with the release bot's token and the SHA256SUMS it just published.
import { ExitError } from './exit-error.ts';
import type { OpenPullRequest } from './find-open-atc-pin-pr.ts';
import { findOpenATCPinPR } from './find-open-atc-pin-pr.ts';
import { readATCPinBranch } from './read-atc-pin-branch.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import { runProcess } from './run-process.ts';
import { withExitCode } from './with-exit-code.ts';

export interface OpenATCPinPROptions extends ScriptIO {
  // `<version> <SHA256SUMS file>`
  readonly args: readonly string[];

  // the clone's root, where git and pin-agent-atc.sh run
  readonly cwd: string;
}

const repo = 'zgeoff/cloud';
const branch = 'atc-pin/agent-image';

// One pull request carries the newest release: a later release replaces the branch, its title and
// body, and first turns that pull request's auto-merge off, so the new pin waits for its own
// checks. It stops with no push when main or the branch already pins a newer release.
export function openATCPinPR(options: Readonly<OpenATCPinPROptions>): Promise<number> {
  return withExitCode(options.printErr, async () => {
    const [version, sums] = parseArgs(options.args);

    const changed = await runPin(options, version, sums);

    if (!changed) {
      return 0;
    }

    const pinned = await readATCPinBranch(options, options.cwd, branch);

    if (isNewerRelease(pinned.version, version)) {
      options.printOut(
        `${branch} already pins atc ${pinned.version}, which is newer than ${version}\n`,
      );

      return 0;
    }

    await sendPin(options, { version, isPushed: pinned.version === version, lease: pinned.lease });

    return 0;
  });
}

function parseArgs(args: readonly string[]): readonly [string, string] {
  const [version = '', sums = ''] = args;

  if (args.length !== 2) {
    throw new ExitError(2, 'usage: open-atc-pin-pr.sh <version> <SHA256SUMS file>');
  }

  return [version, sums];
}

// pins the release on a fresh branch from origin's main; returns whether the Dockerfile changed
async function runPin(options: Readonly<OpenATCPinPROptions>, version: string, sums: string) {
  const cwd = { cwd: options.cwd };

  await runOrExit(options, ['git', 'fetch', '-q', 'origin', 'main'], cwd);
  await runOrExit(options, ['git', 'checkout', '-q', '-B', branch, 'origin/main'], cwd);

  const pin = await runOrExit(options, ['bash', 'scripts/pin-agent-atc.sh', version, sums], cwd);

  options.printOut(pin.stdout.toString());

  const diff = await options.run(['git', 'diff', '--quiet'], cwd);

  if (diff.exitCode > 1) {
    throw new ExitError(diff.exitCode, diff.stderr.toString().trimEnd());
  }

  return diff.exitCode === 1;
}

// an older release's job can finish after a newer one's, so the branch never moves back
function isNewerRelease(pinned: string, version: string) {
  const release = /^\d+\.\d+\.\d+$/u;

  return release.test(pinned) && release.test(version) && Bun.semver.order(pinned, version) === 1;
}

interface PinRelease {
  readonly version: string;

  // the branch already holds this release, as after a run that pushed and then failed
  readonly isPushed: boolean;
  readonly lease: string;
}

interface PinPullRequest extends PinRelease {
  readonly open: OpenPullRequest | undefined;
}

async function sendPin(options: Readonly<OpenATCPinPROptions>, release: PinRelease) {
  const open = await findOpenATCPinPR(options, repo, branch);

  const pr: PinPullRequest = { ...release, open };
  const title = `chore: pin atc ${pr.version} in the agent image`;

  if (pr.isPushed && pr.open !== undefined) {
    options.printOut(`${pr.open.url} already pins atc ${pr.version}\n`);

    return;
  }

  if (!pr.isPushed) {
    await runPush(options, pr, title);
  }

  const sent = await runOrExit(options, buildPRArgv(pr, title));

  options.printOut(sent.stdout.toString());
}

// opens the pull request when none is open, and otherwise points the open one at the new pin
function buildPRArgv(pr: PinPullRequest, title: string) {
  const text = ['--title', title, '--body', buildPinBody(pr.version)];

  if (pr.open === undefined || pr.isPushed) {
    return ['gh', 'pr', 'create', '--repo', repo, '--base', 'main', '--head', branch, ...text];
  }

  return ['gh', 'pr', 'edit', String(pr.open.number), '--repo', repo, ...text];
}

function buildPinBody(version: string) {
  return `Pins atc ${version} in the agent image, with the atc-linux-x64 sum from the release's SHA256SUMS. The agent image workflow turns on auto-merge once the image builds and passes its check and the diff changes only the two atc pins. After the merge, build and check the image as docs/runbooks/agent-image.md describes.`;
}

// turns the open pull request's auto-merge off before the push, so the new pin waits for its own
// checks; the lease refuses the push when the branch moved since it was read
async function runPush(options: Readonly<OpenATCPinPROptions>, pr: PinPullRequest, title: string) {
  if (pr.open?.hasAutoMerge === true) {
    const argv = ['gh', 'pr', 'merge', String(pr.open.number), '--repo', repo, '--disable-auto'];

    const disabled = await runOrExit(options, argv);

    const output = disabled.stdout.toString();

    if (output !== '') {
      options.printErr(output);
    }
  }

  const lease = `--force-with-lease=refs/heads/${branch}:${pr.lease}`;

  await runOrExit(options, ['git', 'commit', '-qam', title], { cwd: options.cwd });

  await runOrExit(options, ['git', 'push', '-q', lease, 'origin', `HEAD:refs/heads/${branch}`], {
    cwd: options.cwd,
  });
}

if (import.meta.main) {
  process.exitCode = await openATCPinPR({
    args: process.argv.slice(2),
    cwd: process.cwd(),
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
