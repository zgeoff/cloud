import { agentImageAlias } from './constants.ts';
import { findJSONField } from './find-json-field.ts';

export interface AgentImagePool {
  // the record list from `impz image ls --json`
  readonly images: unknown;

  // the image that just passed its check
  readonly newImage: string;

  // every image name or alias that an atc target boots
  readonly targetImages: readonly string[];

  // images that only a switch pinned, with no passing check
  readonly switchOnlyImages: readonly string[];
}

// the passing images to keep, the new one included
const keptPassingImages = 2;

export function pickAgentImagesToUnpin(retention: Readonly<AgentImagePool>): string[] {
  const records = toAgentImageRecords(retention.images);

  // A pin shows a passing check, except on an image that switch-agent-image pinned for a target:
  // that one takes no slot of the passing ones, whether a target boots it or has moved away.
  const passing = records
    .filter(
      (record) =>
        record.pinned &&
        record.name !== retention.newImage &&
        !retention.switchOnlyImages.includes(record.name),
    )
    .toSorted((left, right) => right.createdAt.localeCompare(left.createdAt));

  const kept = new Set([
    retention.newImage,
    ...passing.slice(0, keptPassingImages - 1).map((record) => record.name),
    ...resolveTargetImages(retention.images, retention.targetImages),

    // the image the alias names stays, though a target may not boot it yet
    ...records
      .filter((record) => record.aliases.includes(agentImageAlias))
      .map((record) => record.name),
  ]);

  return records
    .filter((record) => record.pinned && !kept.has(record.name))
    .map((record) => record.name);
}

interface AgentImageRecord {
  readonly name: string;
  readonly createdAt: string;
  readonly pinned: boolean;
  readonly aliases: readonly string[];
}

// A target's image is an image name or an alias, and an alias counts as the image it names now.
// An alias that names no image resolves to nothing, and a name that is no alias stays as it is.
export function resolveTargetImages(
  images: unknown,
  targetImages: readonly string[],
): readonly string[] {
  const records = toAgentImageRecords(images);

  return targetImages.flatMap((target) => [
    target,
    ...records.filter((record) => record.aliases.includes(target)).map((record) => record.name),
  ]);
}

function toAgentImageRecords(images: unknown): readonly AgentImageRecord[] {
  if (!Array.isArray(images)) {
    return [];
  }

  const list: readonly unknown[] = images;

  return list.flatMap((record) => {
    const name = findJSONField(record, 'name');
    const createdAt = findJSONField(record, 'createdAt');

    return typeof name === 'string' && name.startsWith('agent-')
      ? [
          {
            name,
            createdAt: typeof createdAt === 'string' ? createdAt : '',
            pinned: findJSONField(record, 'pinned') === true,
            aliases: toAliases(findJSONField(record, 'aliases')),
          },
        ]
      : [];
  });
}

function toAliases(aliases: unknown): readonly string[] {
  if (!Array.isArray(aliases)) {
    return [];
  }

  const list: readonly unknown[] = aliases;

  return list.filter((alias): alias is string => typeof alias === 'string');
}
