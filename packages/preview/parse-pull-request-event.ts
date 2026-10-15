export type PullRequestAction = 'open' | 'update' | 'close';

export interface PullRequestEvent {
  readonly action: PullRequestAction;

  // owner/name of the repository the pull request targets
  readonly repo: string;
  readonly number: number;
  readonly headSHA: string;

  // the head branch lives in another repository, such as a fork
  readonly fromFork: boolean;
}

// opened and reopened open a preview, synchronize moves its head, and closed ends it, merged or
// not; every other action, such as labeled, changes nothing
const actions = new Map<string, PullRequestAction>([
  ['opened', 'open'],
  ['reopened', 'open'],
  ['synchronize', 'update'],
  ['closed', 'close'],
]);

// The fields of GitHub's pull_request payload that the service reads
// (https://docs.github.com/en/webhooks/webhook-events-and-payloads#pull_request), or null for an
// action that changes nothing. A fork's head repository is null once the fork is deleted.
export function parsePullRequestEvent(payload: unknown): PullRequestEvent | null {
  const event = requireObject(payload, 'payload');
  const action = actions.get(requireString(event['action'], 'action'));

  if (action === undefined) {
    return null;
  }

  const repo = requireString(
    requireObject(event['repository'], 'repository')['full_name'],
    'repository.full_name',
  );

  const head = requireObject(
    requireObject(event['pull_request'], 'pull_request')['head'],
    'pull_request.head',
  );

  const headRepo =
    head['repo'] === null ? null : requireObject(head['repo'], 'pull_request.head.repo');

  return {
    action,
    repo,
    number: requirePullRequestNumber(event['number']),
    headSHA: requireCommitSHA(head['sha']),
    fromFork: headRepo?.['full_name'] !== repo,
  };
}

function requireObject(value: unknown, field: string): Readonly<Record<string, unknown>> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new TypeError(`the payload has no ${field} object`);
  }

  return value as Readonly<Record<string, unknown>>;
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value === '') {
    throw new TypeError(`the payload has no ${field}`);
  }

  return value;
}

function requirePullRequestNumber(value: unknown): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1) {
    throw new TypeError('the payload has no pull request number');
  }

  return value;
}

function requireCommitSHA(value: unknown): string {
  if (typeof value !== 'string' || !/^[\da-f]{40}$/u.test(value)) {
    throw new TypeError('the payload has no full head commit SHA');
  }

  return value;
}
