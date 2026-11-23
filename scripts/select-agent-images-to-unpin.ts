import { findJSONField } from './find-json-field.ts';

export interface AgentImageRetention {
  // the record list from `impz image ls --json`
  readonly images: unknown;

  // the image that just passed its check
  readonly newImage: string;

  // every image that an atc target boots
  readonly targetImages: readonly string[];
}

// the passing images to keep, the new one included
const keptPassingImages = 2;

export function selectAgentImagesToUnpin(retention: Readonly<AgentImageRetention>): string[] {
  const records = toAgentImageRecords(retention.images);

  // an image passed its check when it is pinned, since only a passing build pins its image
  const passing = records
    .filter((record) => record.pinned || record.name === retention.newImage)
    .toSorted((left, right) => right.createdAt.localeCompare(left.createdAt))
    .filter((record) => record.name !== retention.newImage);

  const kept = new Set([
    retention.newImage,
    ...passing.slice(0, keptPassingImages - 1).map((record) => record.name),
    ...retention.targetImages,
  ]);

  return records
    .filter((record) => record.pinned && !kept.has(record.name))
    .map((record) => record.name);
}

const agentImagePattern = /^agent-[\da-f]{7,40}$/u;

interface AgentImageRecord {
  readonly name: string;
  readonly createdAt: string;
  readonly pinned: boolean;
}

function toAgentImageRecords(images: unknown): readonly AgentImageRecord[] {
  if (!Array.isArray(images)) {
    return [];
  }

  const list: readonly unknown[] = images;

  return list.flatMap((record) => {
    const name = findJSONField(record, 'name');
    const createdAt = findJSONField(record, 'createdAt');

    return typeof name === 'string' && agentImagePattern.test(name)
      ? [
          {
            name,
            createdAt: typeof createdAt === 'string' ? createdAt : '',
            pinned: findJSONField(record, 'pinned') === true,
          },
        ]
      : [];
  });
}
