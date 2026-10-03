import { describe, expect, test } from 'bun:test';
import { requireATCGatewayInputs } from './require-atc-gateway-inputs.ts';

const image = `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`;
const daemonID = '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b';
const daemonAddress = '100.69.47.33:8415';
const token = 'x'.repeat(32);
const env = { ATC_GATEWAY_TOKEN_GEOFFCLOUD: token };

describe('requireATCGatewayInputs', () => {
  test('returns the daemon and its token when every input is set', () => {
    expect(requireATCGatewayInputs({ image, daemonID, daemonAddress }, env)).toEqual({
      daemonID,
      daemonAddress,
      token,
    });
  });

  test('refuses the fixture stand-in image', () => {
    const standIn =
      'ghcr.io/zgeoff/atc-gateway:2.10.0@sha256:86cd2af8f297cb5143cee19e71b921d6ba0bc3e3a004d6498be7533b34a068be';

    expect(() => requireATCGatewayInputs({ image: standIn, daemonID, daemonAddress }, env)).toThrow(
      'fixture stand-in',
    );

    expect(() =>
      requireATCGatewayInputs(
        { image: 'ghcr.io/zgeoff/atc-gateway:2.10.0', daemonID, daemonAddress },
        env,
      ),
    ).toThrow('fixture stand-in');
  });
});

describe('requireATCGatewayInputs daemon', () => {
  test('refuses to deploy without a pinned daemonID', () => {
    expect(() => requireATCGatewayInputs({ image, daemonAddress }, env)).toThrow(
      'atcGateway.daemonID is unset',
    );

    expect(() => requireATCGatewayInputs({ image, daemonID: '', daemonAddress }, env)).toThrow(
      'atcGateway.daemonID is unset',
    );
  });

  test('refuses a daemonID that is not a lowercase UUID', () => {
    expect(() =>
      requireATCGatewayInputs({ image, daemonID: daemonID.toUpperCase(), daemonAddress }, env),
    ).toThrow('lowercase UUID');

    expect(() =>
      requireATCGatewayInputs({ image, daemonID: 'geoffcloud', daemonAddress }, env),
    ).toThrow('lowercase UUID');
  });

  test('refuses a missing or malformed daemon address', () => {
    expect(() => requireATCGatewayInputs({ image, daemonID }, env)).toThrow(
      'atcGateway.daemonAddress',
    );

    expect(() =>
      requireATCGatewayInputs({ image, daemonID, daemonAddress: '100.69.47.33' }, env),
    ).toThrow('atcGateway.daemonAddress');

    expect(
      requireATCGatewayInputs({ image, daemonID, daemonAddress: '[fd7a::1]:8415' }, env)
        .daemonAddress,
    ).toBe('[fd7a::1]:8415');
  });
});

describe('requireATCGatewayInputs token', () => {
  test('refuses a missing, padded or short token, without echoing it', () => {
    const config = { image, daemonID, daemonAddress };

    expect(() => requireATCGatewayInputs(config, {})).toThrow(
      'ATC_GATEWAY_TOKEN_GEOFFCLOUD is empty',
    );

    expect(() => requireATCGatewayInputs(config, { ATC_GATEWAY_TOKEN_GEOFFCLOUD: '' })).toThrow(
      'ATC_GATEWAY_TOKEN_GEOFFCLOUD is empty',
    );

    expect(() =>
      requireATCGatewayInputs(config, { ATC_GATEWAY_TOKEN_GEOFFCLOUD: `${token}\n` }),
    ).toThrow('no whitespace');

    expect(() =>
      requireATCGatewayInputs(config, { ATC_GATEWAY_TOKEN_GEOFFCLOUD: `${token}\n${token}` }),
    ).toThrow('no whitespace');

    expect(() =>
      requireATCGatewayInputs(config, { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'short-secret-value' }),
    ).toThrow(/^ATC_GATEWAY_TOKEN_GEOFFCLOUD is shorter than 32 bytes$/u);
  });
});
