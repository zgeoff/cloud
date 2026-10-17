import type { BumpBranchInput } from './create-bump-branch.ts';
import { createBumpBranch } from './create-bump-branch.ts';
import { managedBumpLabels } from './managed-bump-labels.ts';
import { readBumpPRs } from './read-bump-prs.ts';
import { runChecked } from './run-checked.ts';
import { runGitSteps } from './run-git-steps.ts';
import { toRunOptions } from './to-run-options.ts';
import type { BumpBranch, BumpContext, BumpPR } from './types.ts';
import { updateBumpLabels } from './update-bump-labels.ts';

export interface BumpPRInput extends BumpBranchInput {
  readonly body: string;
  readonly labels: readonly string[];
}

// Opens or updates the pull request that bumps one dependency to a release, one per dependency
// on release-check/<dependency>. A person's hold or rejection lasts while the bump targets the
// same release (docs/runbooks/release-check.md). It gives the exit code.
export async function openReleaseBumpPR(context: BumpContext, input: BumpPRInput): Promise<number> {
  const unmanaged = input.labels.find((label) => !managedBumpLabels.has(label));

  if (unmanaged !== undefined) {
    context.printErr(`not a release bump label: '${unmanaged}'\n`);

    return 2;
  }

  const branch = await createBumpBranch(context, input);

  if (branch === 'unchanged') {
    return 0;
  }

  const opened = branch instanceof Error ? branch : await openBranchPR(context, input, branch);

  return opened instanceof Error ? printError(context, opened) : 0;
}

async function openBranchPR(context: BumpContext, input: BumpPRInput, branch: BumpBranch) {
  const prs = await readBumpPRs(context, branch.name, 'open');

  const labelled = prs instanceof Error ? prs : await createLabels(context, input.labels);

  if (labelled instanceof Error) {
    return labelled;
  }

  const [pr] = prs instanceof Error ? [] : prs;

  const rejected =
    pr === undefined && branch.sameRelease ? await isRejected(context, branch) : false;

  if (rejected !== false) {
    return rejected === true ? null : rejected;
  }

  return branch.same
    ? updateUnchangedPR(context, { input, branch, pr })
    : updatePushedPR(context, { input, branch, pr });
}

// A person who closed the pull request for the branch's head rejected its release. A failed
// lookup stops the bump, since it cannot tell a rejected release from a new one.
async function isRejected(context: BumpContext, branch: BumpBranch): Promise<boolean | Error> {
  const closed = await readBumpPRs(context, branch.name, 'closed');

  const rejected =
    closed instanceof Error ? closed : closed.find((each) => each.head === branch.lease);

  if (rejected === undefined || rejected instanceof Error) {
    return rejected ?? false;
  }

  context.printOut(
    `#${rejected.number} was closed with this bump; delete ${branch.name} to open it again\n`,
  );

  return true;
}

async function createLabels(context: BumpContext, labels: readonly string[]) {
  for (const label of labels) {
    const [color, description] = managedBumpLabels.get(label) ?? ['', ''];

    const created = await runChecked(
      context.run,
      [
        'gh',
        'label',
        'create',
        label,
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        color,
        '--description',
        description,
      ],
      toRunOptions(context),
    );

    if (created instanceof Error) {
      return created;
    }
  }

  return null;
}

interface BumpPRState {
  readonly input: BumpPRInput;
  readonly branch: BumpBranch;
  readonly pr: BumpPR | undefined;
}

// the branch already holds this change: it opens the missing pull request, or brings the open
// one's labels up to date, so a run that failed after its push is repaired by the next
async function updateUnchangedPR(context: BumpContext, state: BumpPRState) {
  if (state.pr === undefined) {
    return createPR(context, state);
  }

  const labelled = await updateBumpLabels(context, state.pr, {
    wanted: state.input.labels,
    keepHold: true,
  });

  if (labelled === undefined) {
    context.printOut(
      `${state.pr.url} already bumps ${state.input.dependency} to ${state.input.version}\n`,
    );
  }

  return labelled;
}

// the open pull request loses auto-merge before the push, so a new head never merges under the
// labels of the release it replaces, even when a later step fails
async function updatePushedPR(context: BumpContext, state: BumpPRState) {
  const disarmed = state.pr === undefined ? undefined : await removeAutoMerge(context, state.pr);
  const ref = `refs/heads/${state.branch.name}`;

  if (disarmed !== undefined) {
    return disarmed;
  }

  const pushed = await runGitSteps(context, [
    ['push', '-q', `--force-with-lease=${ref}:${state.branch.lease}`, 'origin', `HEAD:${ref}`],
  ]);

  if (pushed !== undefined) {
    return pushed;
  }

  return state.pr === undefined
    ? createPR(context, state)
    : updatePRText(context, { ...state, pr: state.pr });
}

async function removeAutoMerge(context: BumpContext, pr: BumpPR) {
  const number = String(pr.number);

  const disabled = pr.autoMerge
    ? await runChecked(
        context.run,
        ['gh', 'pr', 'merge', number, '--repo', 'zgeoff/cloud', '--disable-auto'],
        toRunOptions(context),
      )
    : '';

  if (disabled instanceof Error || !pr.labels.includes('auto-merge')) {
    return disabled instanceof Error ? disabled : undefined;
  }

  const removed = await runChecked(
    context.run,
    ['gh', 'pr', 'edit', number, '--repo', 'zgeoff/cloud', '--remove-label', 'auto-merge'],
    toRunOptions(context),
  );

  return removed instanceof Error ? removed : undefined;
}

async function updatePRText(context: BumpContext, state: BumpPRState & { readonly pr: BumpPR }) {
  const kept = { ...state.pr, labels: state.pr.labels.filter((label) => label !== 'auto-merge') };

  const labelled = await updateBumpLabels(context, kept, {
    wanted: state.input.labels,
    keepHold: state.branch.sameRelease,
  });

  if (labelled !== undefined) {
    return labelled;
  }

  const args = [
    'pr',
    'edit',
    String(state.pr.number),
    '--repo',
    'zgeoff/cloud',
    '--title',
    state.branch.title,
    '--body-file',
    '-',
  ];

  return runGH(context, args, state.input.body);
}

function createPR(context: BumpContext, state: BumpPRState) {
  return runGH(
    context,
    [
      'pr',
      'create',
      '--repo',
      'zgeoff/cloud',
      '--base',
      'main',
      '--head',
      state.branch.name,
      '--title',
      state.branch.title,
      '--body-file',
      '-',
      '--label',
      state.input.labels.join(','),
    ],
    state.input.body,
  );
}

// runs gh with the body on stdin and prints what it prints, the pull request's URL
async function runGH(context: BumpContext, args: readonly string[], body: string) {
  const printed = await runChecked(context.run, ['gh', ...args], toRunOptions(context, body));

  if (printed instanceof Error) {
    return printed;
  }

  context.printOut(printed);

  return null;
}

function printError(context: BumpContext, error: Readonly<Error>) {
  context.printErr(`${error.message}\n`);

  return 1;
}
