import type { PullRequestFile } from './build-github-client.ts';

const sdkPackage = '@anthropic-ai/claude-agent-sdk';

export function hasSDKPinChange(files: readonly PullRequestFile[]): boolean {
  return files.some((file) => isManifest(file.path) && hasChangedSDKLine(file.patch));
}

function isManifest(path: string): boolean {
  const name = path.split('/').at(-1);

  return name === 'package.json' || name === 'bun.lock';
}

function hasChangedSDKLine(patch: string | null): boolean {
  // GitHub leaves out a diff too large to show, and a needless run costs less than a missed one
  if (patch === null) {
    return true;
  }

  // a unified diff's changed lines start with + or -, and its hunk headers with @@
  return patch.split('\n').some((line) => /^[+-]/u.test(line) && line.includes(`"${sdkPackage}`));
}
