import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for the GitHub CLI calls that open-atc-pin-pr.ts makes. Checked against the GitHub CLI
// manual (gh_pr_create, gh_pr_edit, gh_pr_merge, gh_pr_list) and gh 2.99.0's JSON, not real calls,
// which would open pull requests.
export interface StubPinPRGhScenario {
  // the open pull requests `gh pr list --json number,url,autoMergeRequest` prints
  readonly openPRs: readonly unknown[];
}

export function buildStubPinPRGh(scenario: Readonly<StubPinPRGhScenario>): StubHandler {
  return (call) => (call.argv[0] === 'gh' ? buildGhAnswer(scenario, call) : undefined);
}

// The manual leaves unsettled what `pr merge --disable-auto` prints off a terminal, so it prints
// nothing here; open-atc-pin-pr.ts reads nothing from it. `pr create` prints the new URL.
function buildGhAnswer(scenario: Readonly<StubPinPRGhScenario>, call: StubCall): StubAnswer {
  const [, group, verb, number] = call.argv;
  const command = `${group ?? ''} ${verb ?? ''}`;

  if (command === 'pr list') {
    return { stdout: `${JSON.stringify(scenario.openPRs)}\n` };
  }

  if (command === 'pr merge' && call.argv.includes('--disable-auto')) {
    return {};
  }

  if (command === 'pr create' || command === 'pr edit') {
    const pr = command === 'pr create' ? '200' : (number ?? '');

    return { stdout: `https://github.com/zgeoff/cloud/pull/${pr}\n` };
  }

  return { exitCode: 97, stderr: `unexpected: ${JSON.stringify(call.argv)}\n` };
}
