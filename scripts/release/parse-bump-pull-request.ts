import { findJSONField } from '../find-json-field.ts';
import type { BumpPullRequest } from './decide.ts';

// Parses what `gh pr view <number> --json` prints for the fields decide reads, or gives an Error.
// Only Actions check runs count as checks: a commit status, such as a review bot's, does not.
export function parseBumpPullRequest(number: number, text: string): BumpPullRequest | Error {
  const value = tryParseJSON(text);

  const fields = {
    authorLogin: findJSONField(findJSONField(value, 'author'), 'login'),
    isCrossRepository: findJSONField(value, 'isCrossRepository'),
    head: findJSONField(value, 'headRefOid'),
    labels: collectStrings(findJSONField(value, 'labels'), 'name'),
    files: collectStrings(findJSONField(value, 'files'), 'path'),
    commits: collectCommits(findJSONField(value, 'commits')),
    checkRuns: collectCheckRuns(findJSONField(value, 'statusCheckRollup')),
  };

  const missing = Object.entries(fields).find(
    (entry: readonly [string, unknown]) => entry[1] === null || entry[1] === undefined,
  )?.[0];

  if (
    missing !== undefined ||
    typeof fields.authorLogin !== 'string' ||
    typeof fields.isCrossRepository !== 'boolean' ||
    typeof fields.head !== 'string'
  ) {
    return new Error(`gh pr view ${number} printed no usable ${missing ?? 'author or head'}`);
  }

  return {
    number,
    authorLogin: fields.authorLogin,
    isCrossRepository: fields.isCrossRepository,
    head: fields.head,
    labels: fields.labels ?? [],
    files: fields.files ?? [],
    commits: fields.commits ?? [],
    checkRuns: fields.checkRuns ?? [],
  };
}

function tryParseJSON(text: string): unknown {
  try {
    const value: unknown = JSON.parse(text);

    return value;
  } catch {
    return null;
  }
}

// each item's string field, or null when the value is not a list of such items
function collectStrings(value: unknown, key: string): readonly string[] | null {
  if (!Array.isArray(value)) {
    return null;
  }

  const items: readonly unknown[] = value;
  const strings = items.map((item) => findJSONField(item, key));

  return strings.every((item) => typeof item === 'string') ? strings : null;
}

type Commit = BumpPullRequest['commits'][number];

function collectCommits(value: unknown): readonly Commit[] | null {
  if (!Array.isArray(value)) {
    return null;
  }

  const items: readonly unknown[] = value;
  const commits: Commit[] = [];

  for (const item of items) {
    const commit = toCommit(item);

    if (commit === null) {
      return null;
    }

    commits.push(commit);
  }

  return commits;
}

function toCommit(item: unknown): Commit | null {
  const oid = findJSONField(item, 'oid');
  const authorLogins = collectStrings(findJSONField(item, 'authors'), 'login');

  return typeof oid === 'string' && authorLogins !== null ? { oid, authorLogins } : null;
}

type CheckRun = BumpPullRequest['checkRuns'][number];

function collectCheckRuns(value: unknown): readonly CheckRun[] | null {
  if (!Array.isArray(value)) {
    return null;
  }

  const items: readonly unknown[] = value;
  const runs: CheckRun[] = [];

  for (const item of items.filter((each) => findJSONField(each, '__typename') === 'CheckRun')) {
    const run = toCheckRun(item);

    if (run === null) {
      return null;
    }

    runs.push(run);
  }

  return runs;
}

function toCheckRun(item: unknown): CheckRun | null {
  const workflow = findJSONField(item, 'workflowName');
  const name = findJSONField(item, 'name');
  const status = findJSONField(item, 'status');
  const conclusion = findJSONField(item, 'conclusion');

  const isRun =
    typeof workflow === 'string' &&
    typeof name === 'string' &&
    typeof status === 'string' &&
    (typeof conclusion === 'string' || conclusion === null);

  return isRun ? { workflow, name, status, conclusion } : null;
}
