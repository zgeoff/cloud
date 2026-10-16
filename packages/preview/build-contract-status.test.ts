import { expect, test } from 'bun:test';
import { buildContractStatus } from './build-contract-status.ts';

test("it reports success with bun test's counts when the suite passes", () => {
  expect(
    buildContractStatus(
      {
        code: 0,
        output:
          '(pass) overflow > it ends in blocking_limit\n\n 18 pass\n 0 fail\n 54 expect() calls\nRan 18 tests across 6 files. [133.00s]\n',
      },
      600_000,
    ),
  ).toStrictEqual({ state: 'success', description: '18 pass, 0 fail' });
});

test("it reports failure with bun test's counts when a probe fails", () => {
  expect(
    buildContractStatus(
      { code: 1, output: ' 15 pass\n 3 fail\nRan 18 tests across 6 files. [140.00s]\n' },
      600_000,
    ),
  ).toStrictEqual({ state: 'failure', description: '15 pass, 3 fail' });
});

test('it reports failure with the exit code when the run ends before the suite reports', () => {
  expect(
    buildContractStatus(
      { code: 1, output: 'error: lockfile had changes, but lockfile is frozen\n' },
      600_000,
    ),
  ).toStrictEqual({
    state: 'failure',
    description: 'The run exited with 1 before the suite reported',
  });
});

test('it reports failure when a signal ends the run', () => {
  expect(buildContractStatus({ code: null, output: '' }, 600_000)).toStrictEqual({
    state: 'failure',
    description: 'The run exited on a signal before the suite reported',
  });
});

test.each([
  ['the host deadline passes', null],
  ["the guest's timeout ends the run", { code: 124, output: ' 2 pass\n 0 fail\n' }],
  ["the guest's kill after its timeout ends the run", { code: 137, output: '' }],
])('it reports the time limit as a failure when %s', (_, result) => {
  expect(buildContractStatus(result, 600_000)).toStrictEqual({
    state: 'failure',
    description: 'The suite ran past its 10 min limit',
  });
});
