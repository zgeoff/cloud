import { isRecord } from '@zgeoff/std';

export type PullRequestAction = 'open' | 'update' | 'close';

export interface PullRequestEvent {
  readonly action: PullRequestAction;

  readonly repo: string;
  readonly number: number;
  readonly headSHA: string;

  readonly fromFork: boolean;
}

const actions = new Map<string, PullRequestAction>([
  ['opened', 'open'],
  ['reopened', 'open'],
  ['synchronize', 'update'],
  ['closed', 'close'],
]);

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

  // a fork's head repository is null once the fork is deleted
  // (https://docs.github.com/en/webhooks/webhook-events-and-payloads#pull_request)
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
  if (!isRecord(value)) {
    throw new TypeError(`the payload has no ${field} object`);
  }

  return value;
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
