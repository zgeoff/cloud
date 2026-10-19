export function renderPreviewComment(link: string, headSHA: string | null): string {
  if (headSHA === null) {
    return [
      '**Preview ended.** The pull request closed, so its imp is gone and the link serves nothing.',
    ].join('\n');
  }

  return [
    `**Preview:** ${link}`,
    '',
    `Opening the link boots \`${headSHA.slice(0, 7)}\` from \`preview/\` in its own imp, or wakes`,
    'the imp that already runs it. A push rebuilds the preview on the next open. The link works on',
    'the tailnet only.',
  ].join('\n');
}
