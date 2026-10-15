import { expect, test } from 'bun:test';
import { renderPreviewComment } from './render-preview-comment.ts';

test('it renders the link and the short head commit for an open pull request', () => {
  expect(
    renderPreviewComment(
      'http://geoffcloud:8417/acme/greenhouse/17',
      '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
    ),
  ).toMatchInlineSnapshot(`
"**Preview:** http://geoffcloud:8417/acme/greenhouse/17

Opening the link boots \`4d2a7c1\` from \`preview/\` in its own imp, or wakes
the imp that already runs it. A push rebuilds the preview on the next open. The link works on
the tailnet only."
`);
});

test('it renders the end of the preview for a closed pull request', () => {
  expect(
    renderPreviewComment('http://geoffcloud:8417/acme/greenhouse/17', null),
  ).toMatchInlineSnapshot(
    `"**Preview ended.** The pull request closed, so its imp is gone and the link serves nothing."`,
  );
});
