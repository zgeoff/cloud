import { expect, test } from 'bun:test';
import { buildSecretChecksum } from './build-secret-checksum.ts';

test('it gives the same data the same SHA-256 checksum, whatever the order of its keys', () => {
  expect(
    buildSecretChecksum({ 'webhook-url': 'https://example.invalid/1', 'mention.tmpl': 'a' }),
  ).toBe(buildSecretChecksum({ 'mention.tmpl': 'a', 'webhook-url': 'https://example.invalid/1' }));
});

test('it gives the checksum as 64 lowercase hex digits', () => {
  expect(buildSecretChecksum({ 'webhook-url': 'https://example.invalid/1' })).toSatisfy(
    (value: string) => /^[0-9a-f]{64}$/u.test(value),
  );
});

test('it gives data with one value changed another checksum', () => {
  expect(
    buildSecretChecksum({ 'webhook-url': 'https://example.invalid/1', 'mention.tmpl': 'a' }),
  ).not.toBe(
    buildSecretChecksum({ 'webhook-url': 'https://example.invalid/1', 'mention.tmpl': 'b' }),
  );
});

test('it gives data with a value moved to another key another checksum', () => {
  expect(buildSecretChecksum({ first: 'a', second: '' })).not.toBe(
    buildSecretChecksum({ first: '', second: 'a' }),
  );
});
