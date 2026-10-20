import { isNewerVersion } from './is-newer-version.ts';
import { parseReleaseVersion } from './parse-release-version.ts';
import type { ReleaseRecord } from './release-registry.ts';

export interface BumpBodyInput {
  readonly record: ReleaseRecord;
  readonly version: string;

  readonly pinned: readonly string[];
  readonly labels: readonly string[];
}

export function renderBumpBody(input: BumpBodyInput): string {
  const tag = `${input.record.tagPrefix}${input.version}`;
  const url = `https://github.com/${input.record.repo}/releases/tag/${encodeURIComponent(tag).replaceAll('%2F', '/')}`;

  const rows = input.record.pins.map((pin, index) => {
    const from = input.pinned[index] ?? '';

    return `| ${pin.title} | ${from} | ${isOlder(from, input.version) ? input.version : 'unchanged'} |`;
  });

  return [
    `Bumps ${input.record.name} to [${input.version}](${url}). The release check opened this pull request.`,
    '',
    '| Pin | From | To |',
    '| --- | --- | --- |',
    ...rows,
    '',
    ...renderMergeLines(input),
    '',
    `After the merge: ${input.record.rollout}`,
    '',
  ].join('\n');
}

function isOlder(pinned: string, version: string) {
  const held = parseReleaseVersion(pinned);
  const target = parseReleaseVersion(version);

  return held !== undefined && target !== undefined && isNewerVersion(target, held);
}

function renderMergeLines(input: BumpBodyInput) {
  if (input.labels.includes('auto-merge')) {
    return [
      'It merges on its own once every check on its head passes. A change to `nixos/` gets its NixOS checks on `main`, which the host switch waits for.',
    ];
  }

  const reasons = input.labels.flatMap((label) => renderReason(label, input.version));

  return ['It waits for a review, because:', '', ...reasons];
}

const reasonRenderers = new Map<string, (version: string) => string[]>([
  ['update:major', () => ['- it is a major release.']],
  [
    'update:minor',
    (version) =>
      version.startsWith('0.')
        ? ['- it is a minor release of a 0.x dependency, which may break.']
        : [],
  ],
  [
    'migrations',
    () => ['- a release in the bump adds database migrations, which a revert does not undo.'],
  ],
  [
    'sandbox-images-changed',
    () => [
      "- the release changes nixie's sandbox images, which a person adds to impd before the merge, because the `Deploy prod` workflow applies the merged pin (`docs/runbooks/nixie.md`).",
    ],
  ],
]);

function renderReason(label: string, version: string) {
  // the release workflows run without node_modules, so a Map stands in for ts-pattern's match
  return reasonRenderers.get(label)?.(version) ?? [];
}
