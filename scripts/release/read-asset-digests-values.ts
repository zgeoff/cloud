import { collectAssetSums } from './collect-asset-sums.ts';
import type { ReleaseRead, ReleaseReadResult } from './read-release-values.ts';
import type { ReleaseRecord } from './release-registry.ts';
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
  const assetSums = collectAssetSums(assets);

  // a missing digest fails here, before the bump touches the checkout
  const missing = findPinnedAssets(read.record).find((asset) => !Object.hasOwn(assetSums, asset));

  return missing === undefined
    ? { values: { assetSums }, flags: [] }
    : new Error(`the release lists no sha256 digest for ${missing}`);
}

function findPinnedAssets(record: ReleaseRecord) {
  return record.pins.flatMap((pin) =>
    pin.lines.flatMap((line) =>
      Object.values(line.parts).flatMap((part) =>
        part.kind === 'sum' && typeof part.asset === 'string' ? [part.asset] : [],
      ),
    ),
  );
}
