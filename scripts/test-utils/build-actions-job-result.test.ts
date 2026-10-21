import { expect, test } from 'bun:test';
import { buildActionsJobResult } from './build-actions-job-result.ts';

test.each([
  ['every step passed', { build: 'success', smoke_test: 'success' }, 'success'],
  ['a step that continues on error failed', { build: 'success', smoke_test: 'failure' }, 'success'],
  [
    'a step without continue-on-error failed',
    { build: 'failure', smoke_test: 'success' },
    'failure',
  ],
  ['no step reported an outcome', {}, 'success'],
] as const)('it gives the job its result when %s', (_label, outcomes, expected) => {
  const steps = [
    { name: 'Checkout', uses: 'actions/checkout@v7' },
    { name: 'Build', id: 'build', run: 'bun run build' },
    { name: 'Smoke test', id: 'smoke_test', 'continue-on-error': true, run: 'bun run smoke' },
  ];

  expect(buildActionsJobResult(steps, outcomes)).toBe(expected);
});

test('it fails the job when a step whose continue-on-error is false fails', () => {
  const steps = [{ name: 'Build', id: 'build', 'continue-on-error': false, run: 'bun run build' }];

  expect(buildActionsJobResult(steps, { build: 'failure' })).toBe('failure');
});
