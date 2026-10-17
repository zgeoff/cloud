import { collectPinFiles } from './collect-pin-files.ts';
import { findReleaseRecord } from './find-release-record.ts';

interface BumpCommit {
  readonly oid: string;
  readonly authorLogins: readonly string[];
}

// a GitHub Actions check run on the head; a commit status from another app is not one
interface BumpCheckRun {
  readonly workflow: string;
  readonly name: string;
  readonly status: string;
  readonly conclusion: string | null;
}

export interface BumpPullRequest {
  readonly number: number;
  readonly authorLogin: string;
  readonly isCrossRepository: boolean;
  readonly head: string;
  readonly labels: readonly string[];
  readonly files: readonly string[];
  readonly commits: readonly BumpCommit[];
  readonly checkRuns: readonly BumpCheckRun[];
}

export interface DecideInput {
  readonly branch: string;

  // the release check app, as app/<slug>
  readonly appLogin: string;

  // the branch's open pull request from this repository, or undefined when it has none
  readonly pr: BumpPullRequest | undefined;
}

export type Decision =
  | { readonly action: 'merge'; readonly number: number; readonly head: string }
  | { readonly action: 'hold'; readonly number: number; readonly reason: string }
  | { readonly action: 'skip'; readonly reason: string };

// What the release bump merge does with a branch: merge its open bump pull request at the head it
// checked, hold it open with the first rule it breaks, or skip it. The rules, in order, are the
// runbook's (docs/runbooks/release-check.md, "When a bump merges on its own").
export function decide(input: DecideInput): Decision {
  const record = findReleaseRecord(input.branch);

  if (record === undefined) {
    return { action: 'skip', reason: `${input.branch} is not a release check branch` };
  }

  if (input.pr === undefined) {
    return { action: 'skip', reason: `${input.branch} has no open pull request` };
  }

  const reason =
    findAuthorHoldReason(input.pr, input.appLogin) ??
    findLabelHoldReason(input.pr) ??
    findFileHoldReason(input.pr, collectPinFiles(record)) ??
    findCheckHoldReason(input.pr) ??
    findRequiredCheckHoldReason(input.pr);

  if (reason !== undefined) {
    return { action: 'hold', number: input.pr.number, reason };
  }

  return { action: 'merge', number: input.pr.number, head: input.pr.head };
}

const repo = 'zgeoff/cloud';

// the app must open it from this repository, and its bot user must author every commit, so a
// commit anyone else pushed waits for a person, whatever files it touches
function findAuthorHoldReason(pr: BumpPullRequest, appLogin: string) {
  if (pr.authorLogin !== appLogin || pr.isCrossRepository) {
    return `${appLogin} did not open it from ${repo}`;
  }

  const bot = `${appLogin.replace(/^app\//u, '')}[bot]`;

  const others = pr.commits
    .filter((commit) => commit.authorLogins.some((login) => login !== bot))
    .map((commit) => commit.oid.slice(0, 7));

  return others.length > 0 || pr.commits.length === 0
    ? `commits ${others.length > 0 ? others.join(', ') : 'none'} are not all by ${bot}`
    : undefined;
}

function findLabelHoldReason(pr: BumpPullRequest) {
  return !pr.labels.includes('auto-merge') || pr.labels.includes('needs-review')
    ? 'it is not labelled auto-merge without needs-review'
    : undefined;
}

function findFileHoldReason(pr: BumpPullRequest, pinFiles: readonly string[]) {
  const outside = pr.files.filter((file) => !pinFiles.includes(file)).toSorted();

  return outside.length > 0
    ? `it changes ${outside.join(' ')}, which no pin of its dependency writes`
    : undefined;
}

const passed = new Set(['SUCCESS', 'SKIPPED', 'NEUTRAL']);

function findCheckHoldReason(pr: BumpPullRequest) {
  const pending = pr.checkRuns.filter((run) => run.status !== 'COMPLETED');

  if (pending.length > 0) {
    return `waiting for ${pending.map((run) => run.name).join(', ')}`;
  }

  const failed = pr.checkRuns.filter((run) => !passed.has(run.conclusion ?? ''));

  return failed.length > 0
    ? `${failed.map((run) => `${run.name} (${run.conclusion ?? 'null'})`).join(', ')} did not pass`
    : undefined;
}

// A path-triggered workflow can register its check after another workflow finishes, so a check
// the changed files start must have passed. Two workflows name their job fixture, so the workflow
// is part of the name. The ruleset requires only `ci`, and a person's pull request skips nixos.
const requiredChecks: readonly {
  readonly prefix: string;
  readonly workflow: string;
  readonly name: string;
}[] = [
  { prefix: '', workflow: 'CI', name: 'ci' },
  { prefix: 'nixos/', workflow: 'NixOS checks', name: 'nixos' },
  { prefix: 'images/agent/', workflow: 'agent image', name: 'check' },
  { prefix: 'images/atc-gateway/', workflow: 'atc-gateway images', name: 'fixture' },
  { prefix: 'infra/Pulumi.prod.yaml', workflow: 'nixie backup', name: 'fixture' },
];

function findRequiredCheckHoldReason(pr: BumpPullRequest) {
  const missing = requiredChecks.find(
    (check) =>
      (check.prefix === '' || pr.files.some((file) => file.startsWith(check.prefix))) &&
      !pr.checkRuns.some(
        (run) =>
          run.workflow === check.workflow &&
          run.name === check.name &&
          run.conclusion === 'SUCCESS',
      ),
  );

  return missing === undefined ? undefined : `waiting for ${missing.name} (${missing.workflow})`;
}
