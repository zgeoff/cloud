import { expect, test } from 'bun:test';
import { findATCGatewayBackup } from './find-atc-gateway-backup.ts';

test('it builds the restic repository from the endpoint and bucket', () => {
  expect(
    findATCGatewayBackup({
      ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
      ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
    }),
  ).toStrictEqual({
    repository:
      's3:https://0123456789abcdef.r2.cloudflarestorage.com/atc-gateway-backups/atc-gateway',
    password: 'p'.repeat(32),
    accessKeyID: 'a'.repeat(32),
    secretAccessKey: 's'.repeat(64),
  });
});

test('it returns the values untrimmed, whitespace included', () => {
  expect(
    findATCGatewayBackup({
      ATC_GATEWAY_RESTIC_PASSWORD: ' ',
      ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      ATC_GATEWAY_R2_SECRET_ACCESS_KEY: `${'s'.repeat(64)}\n`,
      ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
    }),
  ).toStrictEqual({
    repository:
      's3:https://0123456789abcdef.r2.cloudflarestorage.com/atc-gateway-backups/atc-gateway',
    password: ' ',
    accessKeyID: 'a'.repeat(32),
    secretAccessKey: `${'s'.repeat(64)}\n`,
  });
});

test('it returns undefined when no backup variable is set', () => {
  expect(findATCGatewayBackup({})).toBeUndefined();
});

test('it returns undefined when every backup variable is empty', () => {
  expect(
    findATCGatewayBackup({
      ATC_GATEWAY_RESTIC_PASSWORD: '',
      ATC_GATEWAY_R2_ACCESS_KEY_ID: '',
      ATC_GATEWAY_R2_SECRET_ACCESS_KEY: '',
      ATC_GATEWAY_R2_ENDPOINT: '',
      ATC_GATEWAY_R2_BUCKET: '',
    }),
  ).toBeUndefined();
});

test('it throws, naming the gap, when the bucket is empty and the rest are set', () => {
  expect(() =>
    findATCGatewayBackup({
      ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
      ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      ATC_GATEWAY_R2_BUCKET: '',
    }),
  ).toThrowWithMessage(
    Error,
    "the atc gateway's backup needs every one of ATC_GATEWAY_RESTIC_PASSWORD, ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET; unset: ATC_GATEWAY_R2_BUCKET",
  );
});

test('it throws, naming the gap, when the bucket is undefined and the rest are set', () => {
  expect(() =>
    findATCGatewayBackup({
      ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
      ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      ATC_GATEWAY_R2_BUCKET: undefined,
    }),
  ).toThrowWithMessage(
    Error,
    "the atc gateway's backup needs every one of ATC_GATEWAY_RESTIC_PASSWORD, ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET; unset: ATC_GATEWAY_R2_BUCKET",
  );
});

test('it throws, naming the other four, when only a whitespace password is set', () => {
  expect(() => findATCGatewayBackup({ ATC_GATEWAY_RESTIC_PASSWORD: ' ' })).toThrowWithMessage(
    Error,
    "the atc gateway's backup needs every one of ATC_GATEWAY_RESTIC_PASSWORD, ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET; unset: ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET",
  );
});

test.each([
  'https://0123456789abcdef.r2.cloudflarestorage.com/bucket',
  'https://0123456789abcdef.r2.cloudflarestorage.com/',
  'http://0123456789abcdef.r2.cloudflarestorage.com',
  '0123456789abcdef.r2.cloudflarestorage.com',
])('it refuses the endpoint %s', (endpoint) => {
  expect(() =>
    findATCGatewayBackup({
      ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
      ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      ATC_GATEWAY_R2_ENDPOINT: endpoint,
      ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
    }),
  ).toThrowWithMessage(Error, 'ATC_GATEWAY_R2_ENDPOINT must be an https:// origin with no path');
});

test.each(['a/b', 'ab', 'a'.repeat(64), 'backups-', '-backups', 'Backups', 'atc_backups'])(
  'it refuses the bucket %s',
  (bucket) => {
    expect(() =>
      findATCGatewayBackup({
        ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
        ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        ATC_GATEWAY_R2_BUCKET: bucket,
      }),
    ).toThrowWithMessage(Error, 'ATC_GATEWAY_R2_BUCKET must be a bare bucket name');
  },
);

test.each(['abc', 'a'.repeat(63), '0-backups-9'])('it takes the bucket %s', (bucket) => {
  expect(
    findATCGatewayBackup({
      ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
      ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
      ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
      ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
      ATC_GATEWAY_R2_BUCKET: bucket,
    }),
  ).toStrictEqual({
    repository: `s3:https://0123456789abcdef.r2.cloudflarestorage.com/${bucket}/atc-gateway`,
    password: 'p'.repeat(32),
    accessKeyID: 'a'.repeat(32),
    secretAccessKey: 's'.repeat(64),
  });
});
