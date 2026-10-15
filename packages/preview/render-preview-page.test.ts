import { expect, test } from 'bun:test';
import { renderPreviewPage } from './render-preview-page.ts';

test('it renders a page that reloads while a boot runs', () => {
  expect(
    renderPreviewPage({
      title: 'Preview booting',
      message: 'Booting acme/greenhouse#17.',
      refreshSeconds: 5,
    }),
  ).toMatchInlineSnapshot(`
"<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta http-equiv="refresh" content="5"><title>Preview booting</title></head>
<body style="font-family: system-ui, sans-serif; max-width: 40rem; margin: 3rem auto">
<h1>Preview booting</h1>
<pre style="white-space: pre-wrap">Booting acme/greenhouse#17.</pre>

</body>
</html>
"
`);
});

test('it escapes markup in the message and the action', () => {
  const page = renderPreviewPage({
    title: 'Preview failed',
    message: 'seed: <script>alert("x")</script> & more',
    action: { label: 'Retry', href: '/acme/greenhouse/17?retry=1&"' },
  });

  expect(page).toInclude('seed: &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; more');
  expect(page).toInclude('<a href="/acme/greenhouse/17?retry=1&amp;&quot;">Retry</a>');
});
