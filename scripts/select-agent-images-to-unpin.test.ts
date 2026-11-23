import { expect, test } from 'bun:test';
import { selectAgentImagesToUnpin } from './select-agent-images-to-unpin.ts';

test('it keeps the new image and the newest other passing image, and unpins the rest', () => {
  const unpin = selectAgentImagesToUnpin({
    images: [
      { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: true },
      { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
      { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: true },
      { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
    ],
    newImage: 'agent-ddddddd',
    targetImages: [],
  });

  expect(unpin).toStrictEqual(['agent-aaaaaaa', 'agent-bbbbbbb']);
});

test('it keeps an image that a target boots, however old', () => {
  const unpin = selectAgentImagesToUnpin({
    images: [
      { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: true },
      { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
      { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: true },
      { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
    ],
    newImage: 'agent-ddddddd',
    targetImages: ['agent-aaaaaaa'],
  });

  expect(unpin).toStrictEqual(['agent-bbbbbbb']);
});

test('it ignores an image that failed its check when it picks the newest passing one', () => {
  const unpin = selectAgentImagesToUnpin({
    images: [
      { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: true },
      { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
      { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: false },
      { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
    ],
    newImage: 'agent-ddddddd',
    targetImages: [],
  });

  expect(unpin).toStrictEqual(['agent-aaaaaaa']);
});

test('it leaves unpinned images and images that are not agent images alone', () => {
  const unpin = selectAgentImagesToUnpin({
    images: [
      { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: false },
      { name: 'base', createdAt: '2026-11-02T00:00:00Z', pinned: true },
      { name: 'imp-builder', createdAt: '2026-11-03T00:00:00Z', pinned: true },
      { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
    ],
    newImage: 'agent-ddddddd',
    targetImages: [],
  });

  expect(unpin).toStrictEqual([]);
});

test('it keeps the new image when the list shows it as unpinned and older than another', () => {
  const unpin = selectAgentImagesToUnpin({
    images: [
      { name: 'agent-aaaaaaa', createdAt: '2026-11-09T00:00:00Z', pinned: true },
      { name: 'agent-bbbbbbb', createdAt: '2026-11-08T00:00:00Z', pinned: true },
      { name: 'agent-ddddddd', createdAt: '2026-11-01T00:00:00Z', pinned: false },
    ],
    newImage: 'agent-ddddddd',
    targetImages: [],
  });

  expect(unpin).toStrictEqual(['agent-bbbbbbb']);
});

test('it unpins nothing from a list that is not an array', () => {
  const unpin = selectAgentImagesToUnpin({
    images: { error: 'nope' },
    newImage: 'agent-ddddddd',
    targetImages: [],
  });

  expect(unpin).toStrictEqual([]);
});

test('it gives an image that only a switch pinned no slot among the passing ones', () => {
  const unpin = selectAgentImagesToUnpin({
    images: [
      { name: 'agent-aaaaaaa', createdAt: '2026-11-01T00:00:00Z', pinned: true },
      { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
      { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: true },
      { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
    ],
    newImage: 'agent-aaaaaaa',
    targetImages: ['agent-ccccccc'],
  });

  expect(unpin).toStrictEqual(['agent-bbbbbbb']);
});

test('it unpins an agent image whose name has no commit hash', () => {
  const unpin = selectAgentImagesToUnpin({
    images: [
      { name: 'agent-1', createdAt: '2026-11-01T00:00:00Z', pinned: true },
      { name: 'agent-bbbbbbb', createdAt: '2026-11-02T00:00:00Z', pinned: true },
      { name: 'agent-ccccccc', createdAt: '2026-11-03T00:00:00Z', pinned: true },
      { name: 'agent-ddddddd', createdAt: '2026-11-04T00:00:00Z', pinned: true },
    ],
    newImage: 'agent-ddddddd',
    targetImages: [],
  });

  expect(unpin).toStrictEqual(['agent-1', 'agent-bbbbbbb']);
});
