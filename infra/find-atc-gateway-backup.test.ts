import { describe, expect, test } from 'bun:test';
import { findATCGatewayBackup } from './find-atc-gateway-backup.ts';

const env = {
  ATC_GATEWAY_RESTIC_PASSWORD: 'p'.repeat(32),
  ATC_GATEWAY_R2_ACCESS_KEY_ID: 'a'.repeat(32),
  ATC_GATEWAY_R2_SECRET_ACCESS_KEY: 's'.repeat(64),
  ATC_GATEWAY_R2_ENDPOINT: 'https://0123456789abcdef.r2.cloudflarestorage.com',
  ATC_GATEWAY_R2_BUCKET: 'atc-gateway-backups',
};

describe('findATCGatewayBackup', () => {
  test('builds the restic repository from the endpoint and bucket', () => {
    expect(findATCGatewayBackup(env)).toEqual({
      repository:
        's3:https://0123456789abcdef.r2.cloudflarestorage.com/atc-gateway-backups/atc-gateway',
      password: env.ATC_GATEWAY_RESTIC_PASSWORD,
      accessKeyID: env.ATC_GATEWAY_R2_ACCESS_KEY_ID,
      secretAccessKey: env.ATC_GATEWAY_R2_SECRET_ACCESS_KEY,
    });
  });

  test('returns undefined when no backup variable is set', () => {
    expect(findATCGatewayBackup({})).toBeUndefined();
  });

  test('throws, naming the gap, when only some are set', () => {
    expect(() => findATCGatewayBackup({ ...env, ATC_GATEWAY_R2_BUCKET: '' })).toThrow(
      'unset: ATC_GATEWAY_R2_BUCKET',
    );
  });

  test('refuses an endpoint with a path', () => {
    expect(() =>
      findATCGatewayBackup({
        ...env,
        ATC_GATEWAY_R2_ENDPOINT: `${env.ATC_GATEWAY_R2_ENDPOINT}/bucket`,
      }),
    ).toThrow('https:// origin');
  });

  test('refuses a bucket that is not a bare name', () => {
    expect(() => findATCGatewayBackup({ ...env, ATC_GATEWAY_R2_BUCKET: 'a/b' })).toThrow(
      'bare bucket',
    );
  });
});
