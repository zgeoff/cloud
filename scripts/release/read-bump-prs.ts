import { findJSONField } from '../find-json-field.ts';
import { runChecked } from './run-checked.ts';
import { toRunOptions } from './to-run-options.ts';
import type { BumpContext, BumpPR } from './types.ts';

export async function readBumpPRs(
  context: BumpContext,
  branch: string,
  state: 'open' | 'closed',
): Promise<BumpPR[] | Error> {
  const fields = 'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository';

  const listed = await runChecked(
    context.run,
    [
      'gh',
      'pr',
      'list',
      '--repo',
      'zgeoff/cloud',
      '--head',
      branch,
      '--state',
      state,
      '--json',
      fields,
    ],
    toRunOptions(context),
  );

  if (listed instanceof Error) {
    return listed;
  }

  const prs: unknown = JSON.parse(listed);

  // a fork's pull request can have the same branch name
  return (Array.isArray(prs) ? prs : [])
    .filter((pr: unknown) => findJSONField(pr, 'isCrossRepository') === false)
    .map((pr: unknown) => toBumpPR(pr));
}

function toBumpPR(pr: unknown): BumpPR {
  const labels = findJSONField(pr, 'labels');
  const url = findJSONField(pr, 'url');
  const head = findJSONField(pr, 'headRefOid');

  return {
    number: Number(findJSONField(pr, 'number')),
    url: typeof url === 'string' ? url : '',
    autoMerge: (findJSONField(pr, 'autoMergeRequest') ?? null) !== null,
    labels: Array.isArray(labels)
      ? labels.map((label: unknown) => String(findJSONField(label, 'name')))
      : [],
    head: typeof head === 'string' ? head : '',
  };
}
