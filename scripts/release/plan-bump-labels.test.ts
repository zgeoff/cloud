import { expect, test } from 'bun:test';
import { planBumpLabels } from './plan-bump-labels.ts';

test('it lets a patch update merge on its own', () => {
  expect(planBumpLabels('2.3.1', ['2.3.0', '2.3.0'], [])).toStrictEqual([
    'update:patch',
    'auto-merge',
  ]);
});

test('it lets a minor update from 1.0 on merge on its own', () => {
  expect(planBumpLabels('1.4.0', ['1.3.2'], [])).toStrictEqual(['update:minor', 'auto-merge']);
});

test('it holds a minor update to a 0.x release for review', () => {
  expect(planBumpLabels('0.32.0', ['0.31.0', '0.31.0'], [])).toStrictEqual([
    'update:minor',
    'needs-review',
  ]);
});

test('it holds a patch update to a 0.x release only when a flag says so', () => {
  expect(planBumpLabels('0.31.1', ['0.31.0'], [])).toStrictEqual(['update:patch', 'auto-merge']);
});

test('it holds a major update for review', () => {
  expect(planBumpLabels('5.0.0', ['4.11.0'], [])).toStrictEqual(['update:major', 'needs-review']);
});

test('it counts 0.9 to 1.0 as a major update', () => {
  expect(planBumpLabels('1.0.0', ['0.9.4'], [])).toStrictEqual(['update:major', 'needs-review']);
});

test('it prints each flag and holds its patch update for review', () => {
  expect(
    planBumpLabels('2.3.1', ['2.3.0'], ['migrations', 'sandbox-images-changed']),
  ).toStrictEqual(['update:patch', 'migrations', 'sandbox-images-changed', 'needs-review']);
});

test('it prints the changed sandbox images flag and lets its patch update merge on its own', () => {
  expect(planBumpLabels('2.3.1', ['2.3.0'], ['sandbox-images-changed'])).toStrictEqual([
    'update:patch',
    'sandbox-images-changed',
    'auto-merge',
  ]);
});

test('it labels the largest step across the pins', () => {
  expect(planBumpLabels('5.0.0', ['4.11.0', '4.9.2', '5.0.0'], [])).toStrictEqual([
    'update:major',
    'needs-review',
  ]);
});

test('it ignores pins at the version or newer', () => {
  expect(planBumpLabels('4.12.1', ['4.12.0', '5.0.0', '4.12.1'], [])).toStrictEqual([
    'update:patch',
    'auto-merge',
  ]);
});

test('it compares versions as numbers, not text', () => {
  expect(planBumpLabels('4.10.0', ['4.9.0'], [])).toStrictEqual(['update:minor', 'auto-merge']);
});

test('it fails when no pin is older than the version', () => {
  expect(planBumpLabels('4.12.0', ['4.12.0', '4.13.0'], [])).toStrictEqual(
    new Error('no pinned version is older than 4.12.0'),
  );
});

test('it rejects a pin that is not a release version', () => {
  expect(planBumpLabels('4.12.0', ['4.11.0', 'v4.11.0'], [])).toStrictEqual(
    new Error("not a release version: 'v4.11.0'"),
  );
});

test('it rejects a version that is not a release version', () => {
  expect(planBumpLabels('latest', ['4.11.0'], [])).toStrictEqual(
    new Error("not a release version: 'latest'"),
  );
});
