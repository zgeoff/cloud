import { findJSONField } from '../find-json-field.ts';
import type { Runner } from '../run-process.ts';
import { runChecked } from './run-checked.ts';

// gh lists the newest releases first; a record whose repository publishes other packages' releases
// beside it asks for more of them (ReleaseRecord.releaseLimit)
const defaultReleaseLimit = 30;

export async function readReleaseTags(
  run: Runner,
  repo: string,
  limit = defaultReleaseLimit,
): Promise<string[] | Error> {
  const listed = await runChecked(run, [
    'gh',
    'release',
    'list',
    '-R',
    repo,
    '--exclude-drafts',
    '--exclude-pre-releases',
    '--limit',
    String(limit),
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
