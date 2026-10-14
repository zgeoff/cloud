import { findJSONField } from './find-json-field.ts';
import { parseJSONOutput } from './parse-json-output.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';

export interface OpenPullRequest {
  readonly number: number;
  readonly url: string;
  readonly hasAutoMerge: boolean;
}

// Finds the open pull request from the branch, as gh lists it; undefined when none is open
export async function findOpenATCPinPR(
  io: Readonly<ScriptIO>,
  repo: string,
  branch: string,
): Promise<OpenPullRequest | undefined> {
  const argv = ['gh', 'pr', 'list', '--repo', repo, '--head', branch, '--state', 'open'];

  const listed = await runOrExit(io, [...argv, '--json', 'number,url,autoMergeRequest']);

  const prs = parseJSONOutput(listed.stdout.toString(), 'gh pr list');
  const [first]: readonly unknown[] = Array.isArray(prs) ? prs : [];
  const number = findJSONField(first, 'number');

  if (typeof number !== 'number') {
    return undefined;
  }

  const url = findJSONField(first, 'url');
  const autoMerge = findJSONField(first, 'autoMergeRequest');

  return {
    number,
    url: typeof url === 'string' ? url : '',
    hasAutoMerge: autoMerge !== null && autoMerge !== undefined,
  };
}
