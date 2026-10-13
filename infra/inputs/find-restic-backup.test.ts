import { expect, test } from 'bun:test';
import { findResticBackup } from './find-restic-backup.ts';

test('it builds the restic repository from the endpoint, the bucket and the path', () => {
  expect(
    findResticBackup(
      {
        ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
        ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
      },
      { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
    ),
  ).toStrictEqual({
    repository:
      's3:https://0123456789abcdef.r2.cloudflarestorage.com/atc-gateway-backups/atc-gateway',
    password: 'p'.repeat(32),
    accessKeyID: 'a'.repeat(32),
    secretAccessKey: 's'.repeat(64),
  });
});

test("it reads only the target's own prefix", () => {
  expect(
    findResticBackup(
      {
        ATC_GATEWAY_RESTIC_PASSWORD: 'g'.repeat(32),
        ATC_GATEWAY_R2_ACCESS_KEY_ID: 'g'.repeat(32),
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 'g'.repeat(64),
        ATC_GATEWAY_R2_ENDPOINT: 'https://fedcba9876543210.r2.cloudflarestorage.com',
        ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
        NIXIE_RESTIC_PASSWORD: 'p'.repeat(32),
        NIXIE_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        NIXIE_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        NIXIE_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        NIXIE_R2_BUCKET: 'nixie-backups',
      },
      { prefix: 'NIXIE', label: "nixie's backup", path: 'nixie' },
    ),
  ).toStrictEqual({
    repository: 's3:https://0123456789abcdef.r2.cloudflarestorage.com/nixie-backups/nixie',
    password: 'p'.repeat(32),
    accessKeyID: 'a'.repeat(32),
    secretAccessKey: 's'.repeat(64),
  });
});

test('it returns the values untrimmed, whitespace included', () => {
  expect(
    findResticBackup(
      {
        ATC_GATEWAY_RESTIC_PASSWORD: ` ${'p'.repeat(32)} `,
        ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: `${'s'.repeat(64)}\n`,
        ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
      },
      { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
    ),
  ).toStrictEqual({
    repository:
      's3:https://0123456789abcdef.r2.cloudflarestorage.com/atc-gateway-backups/atc-gateway',
    password: ` ${'p'.repeat(32)} `,
    accessKeyID: 'a'.repeat(32),
    secretAccessKey: `${'s'.repeat(64)}\n`,
  });
});

test('it returns undefined when no backup variable is set', () => {
  expect(
    findResticBackup(
      {},
      { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
    ),
  ).toBeUndefined();
});

test('it returns undefined when only another prefix is set', () => {
  expect(
    findResticBackup(
      {
        ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
        ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
      },
      { prefix: 'NIXIE', label: "nixie's backup", path: 'nixie' },
    ),
  ).toBeUndefined();
});

test('it returns undefined when every backup variable is empty', () => {
  expect(
    findResticBackup(
      {
        ATC_GATEWAY_RESTIC_PASSWORD: '',
        ATC_GATEWAY_R2_ACCESS_KEY_ID: '',
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: '',
        ATC_GATEWAY_R2_ENDPOINT: '',
        ATC_GATEWAY_R2_BUCKET: '',
      },
      { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
    ),
  ).toBeUndefined();
});

test('it throws, naming the gap, when the bucket is empty and the rest are set', () => {
  expect(() =>
    findResticBackup(
      {
        ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
        ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        ATC_GATEWAY_R2_BUCKET: '',
      },
      { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
    ),
  ).toThrowWithMessage(
    Error,
    "the atc gateway's backup needs every one of ATC_GATEWAY_RESTIC_PASSWORD, ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET; unset: ATC_GATEWAY_R2_BUCKET",
  );
});

test('it throws, naming the gap, when the bucket is undefined and the rest are set', () => {
  expect(() =>
    findResticBackup(
      {
        ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
        ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        ATC_GATEWAY_R2_BUCKET: undefined,
      },
      { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
    ),
  ).toThrowWithMessage(
    Error,
    "the atc gateway's backup needs every one of ATC_GATEWAY_RESTIC_PASSWORD, ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET; unset: ATC_GATEWAY_R2_BUCKET",
  );
});

test('it throws, naming the other four, when only a whitespace password is set', () => {
  expect(() =>
    findResticBackup(
      { ATC_GATEWAY_RESTIC_PASSWORD: ' ' },
      { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
    ),
  ).toThrowWithMessage(
    Error,
    "the atc gateway's backup needs every one of ATC_GATEWAY_RESTIC_PASSWORD, ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET; unset: ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET",
  );
});

test("it names the target's label and variables when its set is partial", () => {
  expect(() =>
    findResticBackup(
      { NIXIE_RESTIC_PASSWORD: 'p'.repeat(32) },
      { prefix: 'NIXIE', label: "nixie's backup", path: 'nixie' },
    ),
  ).toThrowWithMessage(
    Error,
    "nixie's backup needs every one of NIXIE_RESTIC_PASSWORD, NIXIE_R2_ACCESS_KEY_ID, NIXIE_R2_SECRET_ACCESS_KEY, NIXIE_R2_ENDPOINT, NIXIE_R2_BUCKET; unset: NIXIE_R2_ACCESS_KEY_ID, NIXIE_R2_SECRET_ACCESS_KEY, NIXIE_R2_ENDPOINT, NIXIE_R2_BUCKET",
  );
});

test.each([
  ['ATC_GATEWAY_RESTIC_PASSWORD', ' '],
  ['ATC_GATEWAY_R2_ACCESS_KEY_ID', '\t'],
  ['ATC_GATEWAY_R2_SECRET_ACCESS_KEY', '\n'],
  ['ATC_GATEWAY_R2_ENDPOINT', '  '],
  ['ATC_GATEWAY_R2_BUCKET', ' \n'],
])('it throws, naming the field, when only whitespace is in %s', (name, blank) => {
  expect(() =>
    findResticBackup(
      {
        ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
        ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
        [name]: blank,
      },
      { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
    ),
  ).toThrowWithMessage(
    Error,
    `the atc gateway's backup needs a value in every one of ATC_GATEWAY_RESTIC_PASSWORD, ATC_GATEWAY_R2_ACCESS_KEY_ID, ATC_GATEWAY_R2_SECRET_ACCESS_KEY, ATC_GATEWAY_R2_ENDPOINT, ATC_GATEWAY_R2_BUCKET; only whitespace: ${name}`,
  );
});

test.each([
  'https://0123456789abcdef.r2.cloudflarestorage.com/bucket',
  'https://0123456789abcdef.r2.cloudflarestorage.com/',
  'https://',
  'http://0123456789abcdef.r2.cloudflarestorage.com',
  '0123456789abcdef.r2.cloudflarestorage.com',
])('it refuses the endpoint %s', (endpoint) => {
  expect(() =>
    findResticBackup(
      {
        ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
        ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        ATC_GATEWAY_R2_ENDPOINT: endpoint,
        ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
      },
      { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
    ),
  ).toThrowWithMessage(Error, 'ATC_GATEWAY_R2_ENDPOINT must be an https:// origin with no path');
});

test.each(['a/b', 'ab', 'a'.repeat(64), 'backups-', '-backups', 'Backups', 'atc_backups'])(
  'it refuses the bucket %s',
  (bucket) => {
    expect(() =>
      findResticBackup(
        {
          ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
          ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
          ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
          ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
          ATC_GATEWAY_R2_BUCKET: bucket,
        },
        { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
      ),
    ).toThrowWithMessage(Error, 'ATC_GATEWAY_R2_BUCKET must be a bare bucket name');
  },
);

test.each(['abc', 'a'.repeat(63), '0-backups-9'])('it takes the bucket %s', (bucket) => {
  expect(
    findResticBackup(
      {
        ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
        ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
        ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
        ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
        ATC_GATEWAY_R2_BUCKET: bucket,
      },
      { prefix: 'ATC_GATEWAY', label: "the atc gateway's backup", path: 'atc-gateway' },
    ),
  ).toStrictEqual({
    repository: `s3:https://0123456789abcdef.r2.cloudflarestorage.com/${bucket}/atc-gateway`,
    password: 'p'.repeat(32),
    accessKeyID: 'a'.repeat(32),
    secretAccessKey: 's'.repeat(64),
  });
});
