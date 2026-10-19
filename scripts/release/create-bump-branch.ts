import { runChecked } from './run-checked.ts';
import { runGitSteps } from './run-git-steps.ts';
import { toRunOptions } from './to-run-options.ts';
import type { BumpBranch, BumpContext } from './types.ts';

export interface BumpBranchInput {
  readonly dependency: string;
  readonly version: string;

  readonly applyPins: () => Promise<Error | undefined>;
}

export async function createBumpBranch(
  context: BumpContext,
  input: BumpBranchInput,
): Promise<BumpBranch | 'unchanged' | Error> {
  const name = `release-check/${input.dependency}`;
  const title = `chore(${input.dependency}): bump ${input.dependency} to ${input.version}`;

  const clean = await probeTreeClean(context);

  // a change another pin left in the tree would ride along in this commit, under this title
  if (!clean) {
    return new Error('the working tree has uncommitted changes; commit or discard them first');
  }

  const pinned = await writeBranchPins(context, input, name);

  if (pinned !== undefined) {
    return pinned;
  }

  const changed = await probeTreeChanged(context);

  return changed ? createBumpCommit(context, { name, title }) : 'unchanged';
}

async function probeTreeClean(context: BumpContext) {
  const unstaged = await context.run(['git', 'diff', '--quiet'], toRunOptions(context));
  const staged = await context.run(['git', 'diff', '--cached', '--quiet'], toRunOptions(context));

  return unstaged.exitCode === 0 && staged.exitCode === 0;
}

async function writeBranchPins(context: BumpContext, input: BumpBranchInput, name: string) {
  const checkedOut = await runGitSteps(context, [
    ['fetch', '-q', 'origin', 'main'],
    ['checkout', '-q', '-B', name, 'origin/main'],
  ]);

  return checkedOut ?? input.applyPins();
}

async function probeTreeChanged(context: BumpContext) {
  const result = await context.run(['git', 'diff', '--quiet'], toRunOptions(context));

  return result.exitCode !== 0;
}

async function createBumpCommit(
  context: BumpContext,
  branch: Pick<BumpBranch, 'name' | 'title'>,
): Promise<BumpBranch | Error> {
  const committed = await runGitSteps(context, [['commit', '-qam', branch.title]]);

  if (committed !== undefined) {
    return committed;
  }

  const lease = await readLease(context, branch.name);

  if (lease instanceof Error || lease === '') {
    return lease instanceof Error ? lease : { ...branch, lease, same: false, sameRelease: false };
  }

  const same = await probeSameChange(context, lease);
  const leaseTitle = await readGitText(context, ['log', '-1', '--format=%s', lease]);

  return { ...branch, lease, same, sameRelease: same || leaseTitle === branch.title };
}

async function readLease(context: BumpContext, name: string) {
  const ref = `refs/heads/${name}`;

  const listed = await context.run(
    ['git', 'ls-remote', '--exit-code', '--heads', 'origin', ref],
    toRunOptions(context),
  );

  if (listed.exitCode === 2) {
    return '';
  }

  const fetched =
    listed.exitCode === 0
      ? await runGitSteps(context, [['fetch', '-q', 'origin', ref]])
      : new Error(listed.stderr.toString().trim());

  return fetched ?? readGitText(context, ['rev-parse', 'FETCH_HEAD']);
}

async function readGitText(context: BumpContext, args: readonly string[]) {
  const text = await runChecked(context.run, ['git', ...args], toRunOptions(context));

  return text instanceof Error ? text : text.trim();
}

async function probeSameChange(context: BumpContext, lease: string) {
  const files = await readGitText(context, ['diff', '--name-only', 'origin/main', 'HEAD']);
  const base = await readGitText(context, ['merge-base', 'origin/main', lease]);

  const branchFiles =
    base instanceof Error ? base : await readGitText(context, ['diff', '--name-only', base, lease]);

  if (files instanceof Error || branchFiles instanceof Error || files !== branchFiles) {
    return false;
  }

  const paths = files.split('\n').filter((file) => file !== '');

  const contents = await context.run(
    ['git', 'diff', '--quiet', lease, 'HEAD', '--', ...paths],
    toRunOptions(context),
  );

  return contents.exitCode === 0;
}
