import { appendFile, readFile } from 'node:fs/promises';
import { findJSONField } from '../find-json-field.ts';
import type { RunResult, Runner } from '../run-process.ts';
import { runProcess } from '../run-process.ts';
import type { BumpPullRequest } from './decide.ts';
import { decide } from './decide.ts';
import { findEventBranch } from './find-event-branch.ts';
import { findReleaseRecord } from './find-release-record.ts';
import { parseBumpPullRequest } from './parse-bump-pull-request.ts';

// The release bump merge workflow's step: reads the event, decides on the branch it names, and
// squash-merges at the checked head with MERGE_TOKEN, the app's token, so the push starts main's
// workflows. It prints the decision, and copies it to GITHUB_STEP_SUMMARY.
export interface RunReleaseBumpMergeOptions {
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly run: Runner;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

export async function runReleaseBumpMerge(
  options: Readonly<RunReleaseBumpMergeOptions>,
): Promise<number> {
  const settings = await loadSettings(options);

  if (typeof settings === 'number') {
    return settings;
  }

  if (settings.branch === undefined) {
    options.printOut(`this ${settings.eventName} event starts no merge decision\n`);

    return 0;
  }

  const pr =
    findReleaseRecord(settings.branch) === undefined
      ? undefined
      : await readOpenPullRequest(options, settings.branch);

  if (typeof pr === 'number') {
    return pr;
  }

  return applyDecision(options, settings, pr);
}

interface Settings {
  readonly eventName: string;
  readonly branch: string | undefined;
  readonly summary: string;
  readonly appLogin: string;
  readonly mergeToken: string;
}

// the workflow's settings and the event's branch, or the exit code of a missing setting
async function loadSettings(options: Readonly<RunReleaseBumpMergeOptions>) {
  const env = options.env;

  if (!hasRunnerSettings(options)) {
    return 2;
  }

  const payload = await loadEvent(options, env['GITHUB_EVENT_PATH'] ?? '');

  if (payload instanceof Error) {
    return 1;
  }

  const eventName = env['GITHUB_EVENT_NAME'] ?? '';
  const repository = env['GITHUB_REPOSITORY'] ?? '';
  const branch = findEventBranch({ name: eventName, payload, repository });

  return requireTokens(options, { eventName, branch, summary: env['GITHUB_STEP_SUMMARY'] ?? '' });
}

// the runner sets each of these for every step; a missing one prints its name
function hasRunnerSettings(options: Readonly<RunReleaseBumpMergeOptions>) {
  const missing = [
    'GITHUB_EVENT_NAME',
    'GITHUB_EVENT_PATH',
    'GITHUB_REPOSITORY',
    'GITHUB_STEP_SUMMARY',
  ].find((name) => (options.env[name] ?? '') === '');

  if (missing !== undefined) {
    options.printErr(`${missing} must be set, as the workflow's runner sets it\n`);
  }

  return missing === undefined;
}

async function loadEvent(options: Readonly<RunReleaseBumpMergeOptions>, path: string) {
  try {
    const text = await readFile(path, 'utf8');

    const payload: unknown = JSON.parse(text);

    return payload;
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);

    options.printErr(`cannot read the event at ${path}: ${reason}\n`);

    return new Error(reason);
  }
}

// an event that starts a decision also needs the app's login and token
function requireTokens(
  options: Readonly<RunReleaseBumpMergeOptions>,
  event: Pick<Settings, 'eventName' | 'branch' | 'summary'>,
): Settings | number {
  const appLogin = options.env['APP_LOGIN'] ?? '';
  const mergeToken = options.env['MERGE_TOKEN'] ?? '';

  if (event.branch !== undefined && appLogin === '') {
    options.printErr('APP_LOGIN must name the release check app, as app/<slug>\n');

    return 2;
  }

  if (event.branch !== undefined && mergeToken === '') {
    options.printErr("MERGE_TOKEN must hold the release check app's token\n");

    return 2;
  }

  return { ...event, appLogin, mergeToken };
}

const repo = 'zgeoff/cloud';

// the branch's open pull request from this repository, since a fork's can have the same branch
// name; undefined when it has none, or gh's exit code when gh fails
async function readOpenPullRequest(
  options: Readonly<RunReleaseBumpMergeOptions>,
  branch: string,
): Promise<BumpPullRequest | undefined | number> {
  const listed = await runGH(options, [
    'pr',
    'list',
    '--repo',
    repo,
    '--head',
    branch,
    '--state',
    'open',
    '--json',
    'number,isCrossRepository',
  ]);

  if (typeof listed === 'number') {
    return listed;
  }

  const number = findOwnNumber(listed.stdout.toString());

  if (number === undefined) {
    return undefined;
  }

  return readPullRequest(options, number);
}

function findOwnNumber(text: string) {
  const prs: unknown = JSON.parse(text);
  const list: readonly unknown[] = Array.isArray(prs) ? prs : [];
  const own = list.find((pr) => findJSONField(pr, 'isCrossRepository') === false);
  const number = findJSONField(own, 'number');

  return typeof number === 'number' ? number : undefined;
}

async function readPullRequest(options: Readonly<RunReleaseBumpMergeOptions>, number: number) {
  const viewed = await runGH(options, [
    'pr',
    'view',
    String(number),
    '--repo',
    repo,
    '--json',
    'author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup',
  ]);

  if (typeof viewed === 'number') {
    return viewed;
  }

  const pr = parseBumpPullRequest(number, viewed.stdout.toString());

  if (pr instanceof Error) {
    options.printErr(`${pr.message}\n`);

    return 1;
  }

  return pr;
}

async function applyDecision(
  options: Readonly<RunReleaseBumpMergeOptions>,
  settings: Settings,
  pr: BumpPullRequest | undefined,
) {
  const decision = decide({ branch: settings.branch ?? '', appLogin: settings.appLogin, pr });

  if (decision.action === 'skip') {
    return printReport(options, settings, `${decision.reason}\n`);
  }

  if (decision.action === 'hold') {
    return printReport(options, settings, `#${decision.number} stays open: ${decision.reason}\n`);
  }

  const merged = await runGH(
    options,
    [
      'pr',
      'merge',
      String(decision.number),
      '--repo',
      repo,
      '--squash',
      '--match-head-commit',
      decision.head,
    ],
    settings.mergeToken,
  );

  if (typeof merged === 'number') {
    return merged;
  }

  return printReport(options, settings, `merged #${decision.number} at ${decision.head}\n`);
}

// prints the text and copies it to the step summary
async function printReport(
  options: Readonly<RunReleaseBumpMergeOptions>,
  settings: Settings,
  text: string,
) {
  options.printOut(text);

  await appendFile(settings.summary, text);

  return 0;
}

// runs gh with GH_TOKEN, or with the token given; a failure prints gh's stderr and gives its exit
// code
async function runGH(
  options: Readonly<RunReleaseBumpMergeOptions>,
  args: readonly string[],
  token?: string,
): Promise<RunResult | number> {
  const env = token === undefined ? options.env : { ...options.env, GH_TOKEN: token };

  const result = await options.run(['gh', ...args], { env });

  if (result.exitCode !== 0) {
    options.printErr(result.stderr.toString());

    return result.exitCode;
  }

  return result;
}

if (import.meta.main) {
  process.exitCode = await runReleaseBumpMerge({
    env: process.env,
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
