import { collectAssetSums } from './collect-asset-sums.ts';
import type { ReleaseRead, ReleaseReadResult } from './read-release-values.ts';
import { runChecked } from './run-checked.ts';

export async function readAssetDigestsValues(
  read: ReleaseRead,
): Promise<ReleaseReadResult | Error> {
  const listed = await runChecked(read.run, [
    'gh',
    'api',
    `repos/${read.record.repo}/releases/tags/${read.record.tagPrefix}${read.version}`,
    '--jq',
    '[.assets[] | {name, digest}]',
  ]);

  if (listed instanceof Error) {
    return listed;
  }

  const assets: unknown = JSON.parse(listed);

  return { values: { assetSums: collectAssetSums(assets) }, flags: [] };
}
