import { expect, mock, test } from 'bun:test';
import { checkCINeeds } from './check-ci-needs.ts';

function setupTest() {
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { printOut, printErr };
}

test('it passes when every needed job succeeded or its gate skipped it', () => {
  const ctx = setupTest();

  const status = checkCINeeds({
    needs: JSON.stringify({
      lint: { result: 'success', outputs: {} },
      'test-image': { result: 'skipped', outputs: {} },
    }),
    ...ctx,
  });

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['check-ci-needs: 2 jobs passed or were skipped\n'],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);
});

test('it fails and names each needed job that failed or was cancelled', () => {
  const ctx = setupTest();

  const status = checkCINeeds({
    needs: JSON.stringify({
      lint: { result: 'failure', outputs: {} },
      unit: { result: 'success', outputs: {} },
      'test-image': { result: 'cancelled', outputs: {} },
    }),
    ...ctx,
  });

  expect(status).toBe(1);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['check-ci-needs: lint ended failure\ncheck-ci-needs: test-image ended cancelled\n'],
  ]);
});

test('it fails a needed job that reports no result', () => {
  const ctx = setupTest();
  const status = checkCINeeds({ needs: JSON.stringify({ lint: { outputs: {} } }), ...ctx });

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['check-ci-needs: lint ended without a result\n'],
  ]);
});

test.each([
  ['unset', undefined],
  ['not JSON', 'lint=success'],
  ['an array', '[]'],
  ['an empty object', '{}'],
])('it refuses NEEDS that is %s', (_label, needs) => {
  const ctx = setupTest();
  const status = checkCINeeds({ needs, ...ctx });

  expect(status).toBe(2);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['check-ci-needs: NEEDS must hold the toJSON(needs) of at least one job\n'],
  ]);
});
