import { expect, test } from 'bun:test';
import { buildMockDashboardPanel } from './build-mock-dashboard-panel.ts';

test('it builds a default dashboard panel', () => {
  expect(buildMockDashboardPanel()).toStrictEqual({
    title: expect.toSatisfy((title: string) => title.length > 0),
    type: 'timeseries',
    expr: expect.toSatisfy((expr: string) => /^up\{job="[\w-]+"\}$/u.test(expr)),
    legend: expect.toSatisfy((legend: string) => legend.length > 0),
    width: expect.toSatisfy(
      (width: number) => Number.isInteger(width) && width >= 1 && width <= 24,
    ),
    height: expect.toSatisfy(
      (height: number) => Number.isInteger(height) && height >= 1 && height <= 12,
    ),
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockDashboardPanel({ title: 'Backups', type: 'stat', legend: undefined, width: 12 }),
  ).toStrictEqual({
    title: 'Backups',
    type: 'stat',
    expr: expect.toSatisfy((expr: string) => /^up\{job="[\w-]+"\}$/u.test(expr)),
    width: 12,
    height: expect.toSatisfy(
      (height: number) => Number.isInteger(height) && height >= 1 && height <= 12,
    ),
  });
});
