import { expect, test } from 'bun:test';
import { isActionsConditionMet } from './is-actions-condition-met.ts';

test.each([
  ["github.event_name == 'push'", true],
  ["github.event_name == 'PUSH'", true],
  ["github.event_name != 'push'", false],
  ["github.event.workflow_run.conclusion == 'success'", true],
  ['github.event.workflow_run.head_repository.full_name == github.repository', true],
  ['github.event.workflow_run.missing', false],
  ["github.event.workflow_run.missing == ''", true],
  ["!(github.event_name != 'push' || github.repository == 'someone/else')", true],
  ["github.event_name == 'push' && github.repository == 'someone/else'", false],
  ["github.event_name == 'schedule' || github.repository == 'zgeoff/cloud'", true],
  [`\${{ github.event_name == 'push' }}`, true],
  ["'it''s' == 'IT''S'", true],
  ['true', true],
  ['false', false],
])('it evaluates %s as %p', (condition, met) => {
  expect(
    isActionsConditionMet(condition, {
      github: {
        event_name: 'push',
        repository: 'zgeoff/cloud',
        event: {
          workflow_run: { conclusion: 'success', head_repository: { full_name: 'zgeoff/cloud' } },
        },
      },
      needs: {},
    }),
  ).toBe(met);
});

test.each([
  ["needs.decide.outputs.apply == 'true'", 'success', true],
  ["needs.decide.outputs.apply == 'true'", 'failure', false],
  ["always() && needs.decide.result == 'failure'", 'failure', true],
  ['failure()', 'failure', true],
  ['failure()', 'success', false],
  ['success()', 'skipped', false],
  ['cancelled()', 'cancelled', false],
])('it evaluates %s after a need that ended %s as %p', (condition, result, met) => {
  expect(
    isActionsConditionMet(condition, {
      github: { event_name: 'push' },
      needs: { decide: { result, outputs: { apply: 'true' } } },
    }),
  ).toBe(met);
});

test.each([
  ["steps.outcome.outputs.outcome == 'apply'", true],
  ["steps.outcome.outputs.outcome == 'held'", false],
  ["steps.drift.outcome == 'failure'", true],
  ["steps.guard.outputs.verdict == 'hold'", false],
])('it evaluates the step condition %s as %p', (condition, met) => {
  expect(
    isActionsConditionMet(condition, {
      github: { event_name: 'push' },
      needs: {},
      steps: {
        drift: { outcome: 'failure', conclusion: 'success', outputs: {} },
        outcome: { outcome: 'success', conclusion: 'success', outputs: { outcome: 'apply' } },
      },
    }),
  ).toBe(met);
});

test.each([
  ['success()', 'failure', 'failure', false],
  ['failure()', 'failure', 'failure', true],
  ["steps.guard.outputs.verdict == 'apply'", 'failure', 'failure', false],
  ['success()', 'failure', 'success', true],
  ['failure()', 'failure', 'success', false],
  ['success()', 'skipped', 'skipped', true],
])(
  'it evaluates %s after an earlier step whose outcome is %s and conclusion %s as %p',
  (condition, outcome, conclusion, met) => {
    expect(
      isActionsConditionMet(condition, {
        github: { event_name: 'push' },
        needs: {},
        steps: { guard: { outcome, conclusion, outputs: { verdict: 'apply' } } },
      }),
    ).toBe(met);
  },
);

test('it rejects a steps path when no steps context is given', () => {
  expect(() =>
    isActionsConditionMet("steps.outcome.outputs.outcome == 'apply'", {
      github: { event_name: 'push' },
      needs: {},
    }),
  ).toThrowWithMessage(Error, 'unsupported context: steps.outcome.outputs.outcome');
});

test.each([
  ['hashFiles()', 'unsupported function: hashFiles()'],
  [
    "contains(github.event_name, 'push')",
    "unsupported expression: contains(github.event_name, 'push')",
  ],
  ["vars.name == 'x'", 'unsupported context: vars.name'],
  ['github.event', 'github.event is not a primitive'],
  ["(github.event_name == 'push'", 'expected ), found the end'],
  [
    "github.event_name == 'push' 'pull_request'",
    "unexpected 'pull_request' in: github.event_name == 'push' 'pull_request'",
  ],
  ['== true', 'unexpected =='],
])('it rejects %s', (condition, message) => {
  expect(() =>
    isActionsConditionMet(condition, { github: { event_name: 'push', event: {} }, needs: {} }),
  ).toThrowWithMessage(Error, message);
});
