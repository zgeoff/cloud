import { findJSONField } from '../find-json-field.ts';
import type { Runner } from '../run-process.ts';
import { runChecked } from './run-checked.ts';

export async function readReleaseTags(run: Runner, repo: string): Promise<string[] | Error> {
  const listed = await runChecked(run, [
    'gh',
    'release',
    'list',
    '-R',
    repo,
    '--exclude-drafts',
    '--exclude-pre-releases',
    '--limit',
    '30',
    '--json',
    'tagName',
  ]);

  if (listed instanceof Error) {
    return listed;
  }

  const releases: unknown = JSON.parse(listed);

  return (Array.isArray(releases) ? releases : [])
    .map((release: unknown) => findJSONField(release, 'tagName'))
    .filter((tag) => typeof tag === 'string');
}
