import type { StubAnswer, StubHandler } from './build-stub-runner.ts';

// Stands in for the GitHub CLI's pull request calls that the release scripts make, after the gh
// manual (gh_pr_list, gh_pr_view, gh_pr_merge), checked on 2026-10-17 without real calls, since
// those would merge pull requests. Like gh, it prints only the fields that --json names.
export interface StubReleaseGHScenario {
  // what `pr list --state open` and `pr list --state closed` list, newest first
  readonly openPRs?: readonly object[];
  readonly closedPRs?: readonly object[];

  // what `pr view <number>` prints, by number
  readonly prViews?: Readonly<Record<number, object>>;
}

export function buildStubReleaseGH(scenario: StubReleaseGHScenario): StubHandler {
  return (call) => {
    const args = call.argv.slice(1).join(' ');

    return call.argv[0] === 'gh'
      ? (buildListAnswer(scenario, args) ??
          buildViewAnswer(scenario, args) ??
          buildMergeAnswer(args))
      : undefined;
  };
}

function buildListAnswer(scenario: StubReleaseGHScenario, args: string): StubAnswer | undefined {
  const groups =
    /^pr list --repo zgeoff\/cloud --head \S+ --state (?<state>open|closed) --json (?<fields>\S+)$/u.exec(
      args,
    )?.groups;

  if (groups === undefined) {
    return undefined;
  }

  const prs = (groups['state'] === 'open' ? scenario.openPRs : scenario.closedPRs) ?? [];
  const fields = (groups['fields'] ?? '').split(',');

  return { stdout: `${JSON.stringify(prs.map((pr) => pickFields(pr, fields)))}\n` };
}

function buildViewAnswer(scenario: StubReleaseGHScenario, args: string): StubAnswer | undefined {
  const groups = /^pr view (?<number>\d+) --repo zgeoff\/cloud --json (?<fields>\S+)$/u.exec(
    args,
  )?.groups;

  if (groups === undefined) {
    return undefined;
  }

  const view = scenario.prViews?.[Number(groups['number'])];

  // gh's answer for a number the repository has no pull request for
  if (view === undefined) {
    return {
      exitCode: 1,
      stderr: `GraphQL: Could not resolve to a PullRequest with the number of ${groups['number'] ?? ''}. (repository.pullRequest)\n`,
    };
  }

  return { stdout: `${JSON.stringify(pickFields(view, (groups['fields'] ?? '').split(',')))}\n` };
}

// a merge prints nothing off a terminal, as far as the manual says
function buildMergeAnswer(args: string): StubAnswer | undefined {
  const isMerge =
    /^pr merge \d+ --repo zgeoff\/cloud (?:--squash --match-head-commit [0-9a-f]{40}|--disable-auto)$/u.test(
      args,
    );

  return isMerge ? {} : undefined;
}

function pickFields(value: object, fields: readonly string[]): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(value).filter((entry: readonly [string, unknown]) => fields.includes(entry[0])),
  );
}
