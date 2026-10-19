import type { PinValues } from './collect-pin-values.ts';
import type { Pin, ReleaseRecord } from './release-registry.ts';

export interface PublishedImagesBodyInput {
  readonly record: ReleaseRecord;
  readonly version: string;

  readonly held: PinValues;
  readonly planned: PinValues;
  readonly labels: readonly string[];

  readonly runURL: string | undefined;
}

export function renderPublishedImagesBody(input: PublishedImagesBodyInput): string {
  const tag = `${input.record.tagPrefix}${input.version}`;
  const url = `https://github.com/${input.record.repo}/releases/tag/${encodeURIComponent(tag).replaceAll('%2F', '/')}`;
  const by = input.runURL === undefined ? 'the publish workflow' : `[its run](${input.runURL})`;

  const rows = input.record.pins.map((pin) => {
    const group = findShownGroup(pin);
    const from = input.held[pin.id]?.[group] ?? '';
    const to = input.planned[pin.id]?.[group] ?? '';
    const moved = !isSamePin(input.held[pin.id], input.planned[pin.id]);

    return `| ${pin.title} | ${from} | ${moved ? to : 'unchanged'} |`;
  });

  return [
    `Pins the ${input.record.name} at [${input.version}](${url}) to the digests ${by} published. The publish workflow opened this pull request.`,
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

function findShownGroup(pin: Pin) {
  const parts = pin.lines.flatMap((line) => Object.entries(line.parts));

  const shown =
    parts.find((entry) => entry[1].kind === 'version') ??
    parts.find((entry) => entry[1].kind === 'image-tag');

  return shown?.[0] ?? '';
}

function isSamePin(
  held: Readonly<Record<string, string>> | undefined,
  planned: Readonly<Record<string, string>> | undefined,
) {
  return JSON.stringify(held) === JSON.stringify(planned);
}

function renderMergeLines(input: PublishedImagesBodyInput) {
  if (input.labels.includes('auto-merge')) {
    return ['It merges on its own once every check on its head passes.'];
  }

  const update = input.labels.find((label) => label.startsWith('update:'));

  return ['It waits for a review, because:', '', renderReason(update, input.version)];
}

function renderReason(update: string | undefined, version: string) {
  if (update === undefined) {
    return '- it moves no release version, so no update type rates the change.';
  }

  return update === 'update:major'
    ? '- it is a major release.'
    : `- it is a minor release of a 0.x dependency (${version}), which may break.`;
}
