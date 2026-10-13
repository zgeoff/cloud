import { expect, test } from 'bun:test';
import { targetsSchema } from './targets-schema.ts';

test('it accepts a list of targets as given', () => {
  const payload = [
    { name: 'atc', url: 'https://atc.geoff.cloud/healthz' },
    { name: 'nixie', url: 'https://nixie.geoff.cloud/' },
  ];

  expect(targetsSchema.safeParse(payload).data).toStrictEqual(payload);
});

test('it rejects a target with no url', () => {
  const result = targetsSchema.safeParse([
    { name: 'atc', url: 'https://atc.geoff.cloud/healthz' },
    { name: 'nixie' },
  ]);

  expect(result.error?.issues).toPartiallyContain({ path: [1, 'url'] });
});

test('it rejects a target whose name is not a string', () => {
  const result = targetsSchema.safeParse([{ name: 1, url: 'https://atc.geoff.cloud/healthz' }]);

  expect(result.error?.issues).toPartiallyContain({ path: [0, 'name'] });
});
