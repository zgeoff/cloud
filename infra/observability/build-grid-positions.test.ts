import { expect, test } from 'bun:test';
import { buildGridPositions } from './build-grid-positions.ts';

test('it wraps at 24 columns and starts the next row below the tallest panel of the last', () => {
  expect(
    buildGridPositions([
      { width: 12, height: 8 },
      { width: 12, height: 8 },
      { width: 6, height: 5 },
      { width: 6, height: 5 },
      { width: 6, height: 5 },
      { width: 6, height: 5 },
      { width: 24, height: 12 },
    ]),
  ).toStrictEqual([
    { x: 0, y: 0, w: 12, h: 8 },
    { x: 12, y: 0, w: 12, h: 8 },
    { x: 0, y: 8, w: 6, h: 5 },
    { x: 6, y: 8, w: 6, h: 5 },
    { x: 12, y: 8, w: 6, h: 5 },
    { x: 18, y: 8, w: 6, h: 5 },
    { x: 0, y: 13, w: 24, h: 12 },
  ]);
});

test('it advances by the tallest panel in the row, not the last one', () => {
  expect(
    buildGridPositions([
      { width: 12, height: 9 },
      { width: 12, height: 4 },
      { width: 6, height: 5 },
    ]),
  ).toStrictEqual([
    { x: 0, y: 0, w: 12, h: 9 },
    { x: 12, y: 0, w: 12, h: 4 },
    { x: 0, y: 9, w: 6, h: 5 },
  ]);
});

test('it keeps a panel that ends exactly at column 24 on the same row', () => {
  expect(
    buildGridPositions([
      { width: 18, height: 5 },
      { width: 6, height: 5 },
    ]),
  ).toStrictEqual([
    { x: 0, y: 0, w: 18, h: 5 },
    { x: 18, y: 0, w: 6, h: 5 },
  ]);
});

test('it wraps a panel that would end past column 24', () => {
  expect(
    buildGridPositions([
      { width: 18, height: 5 },
      { width: 7, height: 5 },
    ]),
  ).toStrictEqual([
    { x: 0, y: 0, w: 18, h: 5 },
    { x: 0, y: 5, w: 7, h: 5 },
  ]);
});

test('it places no panel for no panels', () => {
  expect(buildGridPositions([])).toStrictEqual([]);
});
