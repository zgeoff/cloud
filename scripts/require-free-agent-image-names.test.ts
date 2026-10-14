import { expect, test } from 'bun:test';
import { requireFreeAgentImageNames } from './require-free-agent-image-names.ts';
import { buildStubImp } from './test-utils/build-stub-imp.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it passes names the imp host does not hold', async () => {
  const imp = buildStubImp({
    images: [{ name: 'agent-14d3c9d', digest: 'imp-build-1' }],
    imps: [{ name: 'agent-check-14d3c9d', image: 'agent-14d3c9d' }],
  });

  const stub = buildStubRunner(imp.handler);

  const result = requireFreeAgentImageNames(
    { run: stub.run, printOut: () => {}, printErr: () => {} },
    { image: 'agent-abc1234', check: 'agent-check-abc1234' },
  );

  await expect(result).toResolve();
});

test('it refuses an image name the host holds', () => {
  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-1' }] });
  const stub = buildStubRunner(imp.handler);

  expect(
    requireFreeAgentImageNames(
      { run: stub.run, printOut: () => {}, printErr: () => {} },
      { image: 'agent-abc1234', check: 'agent-check-abc1234' },
    ),
  ).rejects.toMatchObject({
    exitCode: 1,
    message:
      'image agent-abc1234 already exists: remove it with imp image rm, or build another commit',
  });
});

test('it refuses a check imp name the host holds', () => {
  const imp = buildStubImp({
    images: [],
    imps: [{ name: 'agent-check-abc1234', image: 'agent-1' }],
  });

  const stub = buildStubRunner(imp.handler);

  expect(
    requireFreeAgentImageNames(
      { run: stub.run, printOut: () => {}, printErr: () => {} },
      { image: 'agent-abc1234', check: 'agent-check-abc1234' },
    ),
  ).rejects.toMatchObject({
    exitCode: 1,
    message: 'imp agent-check-abc1234 already exists: remove it with imp rm first',
  });
});
