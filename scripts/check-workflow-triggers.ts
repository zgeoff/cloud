import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { findJSONField } from './find-json-field.ts';
import type { ActionsTriggerEvent } from './is-workflow-triggered.ts';
import { isWorkflowTriggered } from './is-workflow-triggered.ts';

export interface CheckWorkflowTriggersOptions {
  readonly args: readonly string[];
  readonly readText: (path: string) => Promise<string>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

interface TriggerExpectation {
  readonly workflow: string;
  readonly event: ActionsTriggerEvent;
  readonly triggered: boolean;
  readonly violation: string;
}

const usage = 'usage: check-workflow-triggers.ts [repo root]\n';

const expectations: readonly TriggerExpectation[] = [
  // a pull request that changes the checks' inputs learns of a break before it merges, a release
  // bump's included; the switch gate still reads only main's runs
  {
    workflow: 'nixos-checks.yml',
    event: {
      name: 'pull_request',
      baseBranch: 'main',
      files: ['nixos/flake.nix', 'nixos/flake.lock', 'packages/topology/index.ts'],
    },
    triggered: true,
    violation: 'a pull request that changes nixos/ starts no run',
  },
  {
    workflow: 'nixos-checks.yml',
    event: { name: 'schedule' },
    triggered: true,
    violation: 'the nightly schedule starts no run',
  },
  {
    workflow: 'nixos-checks.yml',
    event: { name: 'workflow_dispatch' },
    triggered: true,
    violation: 'a dispatch starts no run',
  },

  // a run started by a check on any branch but a release check branch would bill for nothing
  {
    workflow: 'release-bump-merge.yml',
    event: {
      name: 'workflow_run',
      workflow: 'CI',
      type: 'completed',
      headBranch: 'release-check/imp',
    },
    triggered: true,
    violation: 'a CI run that completes on a release check branch starts no run',
  },
  {
    workflow: 'release-bump-merge.yml',
    event: {
      name: 'workflow_run',
      workflow: 'CI',
      type: 'completed',
      headBranch: 'renovate/example',
    },
    triggered: false,
    violation: 'a CI run that completes on another branch starts a run',
  },
  {
    workflow: 'release-bump-merge.yml',
    event: {
      name: 'workflow_run',
      workflow: 'NixOS checks',
      type: 'completed',
      headBranch: 'release-check/imp',
    },
    triggered: false,
    violation: 'a NixOS checks run that completes starts a run',
  },
];

export async function checkWorkflowTriggers(
  options: Readonly<CheckWorkflowTriggersOptions>,
): Promise<number> {
  const root = parseRoot(options.args);

  if (root === undefined) {
    options.printErr(usage);

    return 2;
  }

  const workflowDir = join(root, '.github', 'workflows');

  const workflows = [
    ...new Set([...expectations.map((expectation) => expectation.workflow), 'audit-fix.yml']),
  ];

  const entries = await Promise.all(
    workflows.map(async (workflow) => {
      const text = await options.readText(join(workflowDir, workflow));

      return [workflow, text] as const;
    }),
  );

  const texts = new Map(entries);

  const violations = expectations
    .filter(
      (expectation) =>
        isWorkflowTriggered(texts.get(expectation.workflow) ?? '', expectation.event) !==
        expectation.triggered,
    )
    .map((expectation) => `${expectation.workflow}: ${expectation.violation}`);

  if (!isRenovateSkipped(texts.get('nixos-checks.yml') ?? '')) {
    violations.push('nixos-checks.yml: a Renovate pull request starts the nixos job');
  }

  if (!isAuditFixPushOnly(texts.get('audit-fix.yml') ?? '')) {
    violations.push(
      'audit-fix.yml: a failed run that is not a push to this repository starts the audit-fix job',
    );
  }

  if (violations.length > 0) {
    options.printErr(violations.map((violation) => `${violation}\n`).join(''));

    return 1;
  }

  options.printOut(
    'check-workflow-triggers: the NixOS checks, the release bump merge and the audit fix start only on their own events\n',
  );

  return 0;
}

// a Renovate bump that touches nixos/ waits for the nightly run instead; the trigger filters
// cannot tell an author apart, so the nixos job's condition holds the rule
const renovateSkip = "github.event.pull_request.user.login != 'zgeoff-renovate[bot]'";

function parseRoot(args: readonly string[]): string | undefined {
  const positionals = tryParsePositionals(args);

  if (positionals === null || positionals.length > 1) {
    return undefined;
  }

  return positionals[0] ?? '.';
}

// util.parseArgs throws on an option it does not know, such as a misspelt flag
function tryParsePositionals(args: readonly string[]): string[] | null {
  try {
    return parseArgs({ args: [...args], options: {}, allowPositionals: true, strict: true })
      .positionals;
  } catch {
    return null;
  }
}

function isRenovateSkipped(workflowText: string): boolean {
  const document: unknown = Bun.YAML.parse(workflowText);
  const condition = findJSONField(findJSONField(findJSONField(document, 'jobs'), 'nixos'), 'if');

  return typeof condition === 'string' && condition.replaceAll(/\s+/gu, ' ').includes(renovateSkip);
}

// the trigger's branches filter matches a fork's branch named main too, so only the job's
// condition can tell a push to this repository from a pull request
const auditFixPushOnly =
  "github.event_name != 'workflow_run' || (github.event.workflow_run.event == 'push' && " +
  "github.event.workflow_run.conclusion == 'failure' && " +
  'github.event.workflow_run.head_repository.full_name == github.repository)';

function isAuditFixPushOnly(workflowText: string): boolean {
  const document: unknown = Bun.YAML.parse(workflowText);

  const condition = findJSONField(
    findJSONField(findJSONField(document, 'jobs'), 'audit-fix'),
    'if',
  );

  return (
    typeof condition === 'string' && condition.replaceAll(/\s+/gu, ' ').trim() === auditFixPushOnly
  );
}

if (import.meta.main) {
  process.exitCode = await checkWorkflowTriggers({
    args: process.argv.slice(2),
    readText: (path) => readFile(path, 'utf8'),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
