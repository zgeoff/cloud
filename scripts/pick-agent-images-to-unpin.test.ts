import { expect, test } from 'bun:test';
import { pickAgentImagesToUnpin } from './pick-agent-images-to-unpin.ts';

test.each([
  [
    'keeps the new image and the newest other passing image, and unpins the rest',
    {
      images: [
        { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: true },
        { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
        { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: true },
        { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
      ],
      newImage: 'agent-ddddddd',
      targetImages: [],
      switchOnlyImages: [],
    },
    ['agent-aaaaaaa', 'agent-bbbbbbb'],
  ],
  [
    'keeps an image that a target boots, however old',
    {
      images: [
        { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: true },
        { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
        { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: true },
        { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
      ],
      newImage: 'agent-ddddddd',
      targetImages: ['agent-aaaaaaa'],
      switchOnlyImages: [],
    },
    ['agent-bbbbbbb'],
  ],
  [
    'ignores an image that failed its check when it picks the newest passing one',
    {
      images: [
        { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: true },
        { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
        { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: false },
        { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
      ],
      newImage: 'agent-ddddddd',
      targetImages: [],
      switchOnlyImages: [],
    },
    ['agent-aaaaaaa'],
  ],
  [
    'leaves unpinned images and images that are not agent images alone',
    {
      images: [
        { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: false },
        { name: 'base', createdAt: '2026-11-02T00:00:00Z', pinned: true },
        { name: 'imp-builder', createdAt: '2026-11-03T00:00:00Z', pinned: true },
        { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
      ],
      newImage: 'agent-ddddddd',
      targetImages: [],
      switchOnlyImages: [],
    },
    [],
  ],
  [
    'keeps the new image when the list shows it as unpinned and older than another',
    {
      images: [
        { name: 'agent-aaaaaaa', createdAt: '2026-11-09T00:00:00Z', pinned: true },
        { name: 'agent-bbbbbbb', createdAt: '2026-11-08T00:00:00Z', pinned: true },
        { name: 'agent-ddddddd', createdAt: '2026-11-01T00:00:00Z', pinned: false },
      ],
      newImage: 'agent-ddddddd',
      targetImages: [],
      switchOnlyImages: [],
    },
    ['agent-bbbbbbb'],
  ],
  [
    'gives an image that only a switch pinned no slot, and unpins it once its target has moved away',
    {
      images: [
        { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: true },
        { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
        { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: true },
      ],
      newImage: 'agent-ccccccc',
      targetImages: [],
      switchOnlyImages: ['agent-bbbbbbb'],
    },
    ['agent-bbbbbbb'],
  ],
  [
    'keeps an image that only a switch pinned while a target boots it',
    {
      images: [
        { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: true },
        { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
        { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: true },
      ],
      newImage: 'agent-ccccccc',
      targetImages: ['agent-bbbbbbb'],
      switchOnlyImages: ['agent-bbbbbbb'],
    },
    [],
  ],
  [
    'unpins an agent image whose name has no commit hash',
    {
      images: [
        { name: 'agent-1', createdAt: '2026-11-01T00:00:00Z', pinned: true },
        { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
        { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: true },
        { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
      ],
      newImage: 'agent-ddddddd',
      targetImages: [],
      switchOnlyImages: [],
    },
    ['agent-1', 'agent-bbbbbbb'],
  ],
])('it %s', (_title, pool, expected) => {
  expect(pickAgentImagesToUnpin(pool)).toStrictEqual(expected);
});

test('it unpins nothing from a list that is not an array', () => {
  const unpin = pickAgentImagesToUnpin({
    images: { error: 'nope' },
    newImage: 'agent-ddddddd',
    targetImages: [],
    switchOnlyImages: [],
  });

  expect(unpin).toStrictEqual([]);
});
