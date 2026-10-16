import type { PullRequestFile } from './build-github-client.ts';

const sdkPackage = '@anthropic-ai/claude-agent-sdk';

// Whether a changed line of a package.json or a bun.lock names the Agent SDK's package. A manifest
// whose diff GitHub leaves out as too large counts as a change, since a needless run costs less
// than a missed one.
export function hasSDKPinChange(files: readonly PullRequestFile[]): boolean {
  return files.some((file) => isManifest(file.path) && hasChangedSDKLine(file.patch));
}

function isManifest(path: string): boolean {
  const name = path.split('/').at(-1);

  return name === 'package.json' || name === 'bun.lock';
}

// a unified diff's changed lines start with + or -, and its hunk headers with @@
function hasChangedSDKLine(patch: string | null): boolean {
  if (patch === null) {
    return true;
  }

  return patch.split('\n').some((line) => /^[+-]/u.test(line) && line.includes(`"${sdkPackage}`));
}
