import { expect, test } from 'bun:test';
import { buildFileHeaders } from './build-file-headers.ts';

test.each([
  ['image/png'],
  ['image/jpeg'],
  ['image/gif'],
  ['image/webp'],
  ['image/avif'],
  ['video/mp4'],
  ['video/webm'],
])('it serves %s inline under its own type', (contentType) => {
  expect(buildFileHeaders({ contentType, filename: 'clip' })).toStrictEqual({
    'Content-Type': contentType,
    'Content-Disposition': `inline; filename="clip"; filename*=UTF-8''clip`,
  });
});

test.each([['image/svg+xml'], ['text/html'], ['application/pdf'], ['application/octet-stream']])(
  'it serves %s as an octet-stream attachment',
  (contentType) => {
    expect(buildFileHeaders({ contentType, filename: 'page' })).toStrictEqual({
      'Content-Type': 'application/octet-stream',
      'Content-Disposition': `attachment; filename="page"; filename*=UTF-8''page`,
    });
  },
);

test('it names a file with quotes and non-ASCII characters in both filename forms', () => {
  expect(
    buildFileHeaders({ contentType: 'image/png', filename: `naïve "plan" (v2)'s.png` })[
      'Content-Disposition'
    ],
  ).toBe(
    `inline; filename="na_ve _plan_ (v2)'s.png"; filename*=UTF-8''na%C3%AFve%20%22plan%22%20%28v2%29%27s.png`,
  );
});
