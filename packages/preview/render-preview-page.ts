export interface PreviewPage {
  readonly title: string;
  readonly message: string;

  // loads the URL after this many seconds, while a boot runs; the link without its query, so a
  // retry flag never rides along into the next load
  readonly refresh?: { readonly seconds: number; readonly url: string };

  // a link the page offers, such as a retry
  readonly action?: { readonly label: string; readonly href: string };
}

// The small HTML page the link serves in place of the preview: booting, failed or ended
export function renderPreviewPage(page: PreviewPage): string {
  const refresh =
    page.refresh === undefined
      ? ''
      : `<meta http-equiv="refresh" content="${page.refresh.seconds}; url=${toHTMLText(page.refresh.url)}">`;

  const action =
    page.action === undefined
      ? ''
      : `<p><a href="${toHTMLText(page.action.href)}">${toHTMLText(page.action.label)}</a></p>`;

  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8">${refresh}<title>${toHTMLText(page.title)}</title></head>
<body style="font-family: system-ui, sans-serif; max-width: 40rem; margin: 3rem auto">
<h1>${toHTMLText(page.title)}</h1>
<pre style="white-space: pre-wrap">${toHTMLText(page.message)}</pre>
${action}
</body>
</html>
`;
}

function toHTMLText(text: string): string {
  return text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}
