import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for the GitHub CLI calls that the release scripts make. The release and commit answers
// match gh 2.102.0 (2026-10-13), and the users 404 gh 2.99.0 (2026-10-14). The pull request and
// label ones follow the gh manual (2026-10-13), since real calls would change pull requests.
interface StubRelease {
  readonly tag: string;
  readonly notes?: string;
  readonly assets?: Readonly<Record<string, string>>;
  readonly commit?: string;
}

export interface StubReleaseGHScenario {
  // each repository's published releases, newest first, as `gh release list` orders them
  readonly releases?: Readonly<Record<string, readonly StubRelease[]>>;

  // what `pr list --state open` and `pr list --state closed` list, newest first
  readonly openPRs?: readonly object[];
  readonly closedPRs?: readonly object[];

  // what `pr view <number>` prints, by number
  readonly prViews?: Readonly<Record<number, object>>;

  // the id of each GitHub user, by login
  readonly users?: Readonly<Record<string, number>>;
}

export function buildStubReleaseGH(scenario: StubReleaseGHScenario): StubHandler {
  return (call) => {
    const args = call.argv.slice(1);

    const answers =
      call.argv[0] === 'gh' ? commands.map((command) => command(scenario, args, call)) : [];

    return answers.find((answer): answer is StubAnswer => answer !== null);
  };
}

type Command = (
  scenario: StubReleaseGHScenario,
  args: readonly string[],
  call: StubCall,
) => StubAnswer | null;

const notFound = { exitCode: 1, stderr: 'release not found\n' };

const commands: readonly Command[] = [
  (scenario, args) => {
    const groups =
      /^release list -R (?<repo>\S+) --exclude-drafts --exclude-pre-releases --limit (?<limit>\d+) --json tagName$/u.exec(
        args.join(' '),
      )?.groups;

    const releases = (scenario.releases?.[groups?.['repo'] ?? ''] ?? []).slice(
      0,
      Number(groups?.['limit']),
    );

    return groups === undefined
      ? null
      : { stdout: `${JSON.stringify(releases.map((each) => ({ tagName: each.tag })))}\n` };
  },
  (scenario, args) => {
    const groups = /^release view (?<tag>\S+) -R (?<repo>\S+) --json body$/u.exec(
      args.join(' '),
    )?.groups;

    const release = findRelease(scenario, groups?.['repo'], groups?.['tag']);

    if (groups === undefined) {
      return null;
    }

    return release?.notes === undefined
      ? notFound
      : { stdout: `${JSON.stringify({ body: release.notes })}\n` };
  },
  (scenario, args) => {
    const groups = /^release download (?<tag>\S+) -R (?<repo>\S+) -p (?<asset>\S+) -O -$/u.exec(
      args.join(' '),
    )?.groups;

    const asset = findRelease(scenario, groups?.['repo'], groups?.['tag'])?.assets?.[
      groups?.['asset'] ?? ''
    ];

    if (groups === undefined) {
      return null;
    }

    return asset === undefined ? notFound : { stdout: asset };
  },
  (scenario, args) => {
    const groups = /^api repos\/(?<repo>[^/]+\/[^/]+)\/commits\/(?<tag>\S+) --jq \.sha$/u.exec(
      args.join(' '),
    )?.groups;

    const commit = findRelease(scenario, groups?.['repo'], groups?.['tag'])?.commit;

    if (groups === undefined) {
      return null;
    }

    return commit === undefined
      ? {
          exitCode: 1,
          stdout: `{"message":"No commit found for SHA: ${groups['tag'] ?? ''}","documentation_url":"https://docs.github.com/rest/commits/commits#get-a-commit","status":"422"}`,
          stderr: `gh: No commit found for SHA: ${groups['tag'] ?? ''} (HTTP 422)\n`,
        }
      : { stdout: `${commit}\n` };
  },
  (scenario, args) => {
    const login = /^api users\/(?<login>\S+)%5Bbot%5D --jq \.id$/u.exec(args.join(' '))?.groups?.[
      'login'
    ];

    const id = scenario.users?.[`${login ?? ''}[bot]`];

    if (login === undefined) {
      return null;
    }

    return id === undefined
      ? {
          exitCode: 1,
          stdout:
            '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/users/users#get-a-user","status":"404"}',
          stderr: 'gh: Not Found (HTTP 404)\n',
        }
      : { stdout: `${id}\n` };
  },
  (scenario, args) => {
    const groups =
      /^pr list --repo zgeoff\/cloud --head \S+ --state (?<state>open|closed) --json (?<fields>\S+)$/u.exec(
        args.join(' '),
      )?.groups;

    const prs = (groups?.['state'] === 'open' ? scenario.openPRs : scenario.closedPRs) ?? [];
    const fields = (groups?.['fields'] ?? '').split(',');

    return groups === undefined
      ? null
      : { stdout: `${JSON.stringify(prs.map((pr) => pickFields(pr, fields)))}\n` };
  },
  (scenario, args) => {
    const groups = /^pr view (?<number>\d+) --repo zgeoff\/cloud --json (?<fields>\S+)$/u.exec(
      args.join(' '),
    )?.groups;

    const view = scenario.prViews?.[Number(groups?.['number'])];

    if (groups === undefined) {
      return null;
    }

    // gh's answer for a number the repository has no pull request for
    return view === undefined
      ? {
          exitCode: 1,
          stderr: `GraphQL: Could not resolve to a PullRequest with the number of ${groups['number'] ?? ''}. (repository.pullRequest)\n`,
        }
      : { stdout: `${JSON.stringify(pickFields(view, (groups['fields'] ?? '').split(',')))}\n` };
  },

  // a merge and a label prints nothing off a terminal, as far as the manual says
  (_scenario, args) =>
    /^pr merge \d+ --repo zgeoff\/cloud (?:--squash --match-head-commit [0-9a-f]{40}|--disable-auto)$/u.test(
      args.join(' '),
    )
      ? {}
      : null,
  (_scenario, args) =>
    args[0] === 'label' &&
    args[1] === 'create' &&
    isFlagged(args, ['--repo', 'zgeoff/cloud'], '--force', '--color', '--description')
      ? {}
      : null,
  (_scenario, args) =>
    args[0] === 'pr' &&
    args[1] === 'create' &&
    isFlagged(args, ['--repo', 'zgeoff/cloud'], '--base', '--head', '--title', '--body-file')
      ? { stdout: 'https://github.com/zgeoff/cloud/pull/200\n' }
      : null,
  (_scenario, args) =>
    args[0] === 'pr' &&
    args[1] === 'edit' &&
    /^\d+$/u.test(args[2] ?? '') &&
    isFlagged(args, ['--repo', 'zgeoff/cloud'])
      ? { stdout: `https://github.com/zgeoff/cloud/pull/${args[2] ?? ''}\n` }
      : null,
];

function findRelease(
  scenario: StubReleaseGHScenario,
  repo: string | undefined,
  tag: string | undefined,
) {
  return scenario.releases?.[repo ?? '']?.find((each) => each.tag === tag);
}

// true when the args hold the flag and value pair, and each of the other flags
function isFlagged(
  args: readonly string[],
  pair: readonly [string, string],
  ...flags: readonly string[]
) {
  const at = args.indexOf(pair[0]);

  return at !== -1 && args[at + 1] === pair[1] && flags.every((flag) => args.includes(flag));
}

function pickFields(value: object, fields: readonly string[]): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(value).filter((entry: readonly [string, unknown]) => fields.includes(entry[0])),
  );
}
