import { describe, expect, test } from 'bun:test';
import { requireATCGatewayInputs } from './require-atc-gateway-inputs.ts';

const image = `ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:${'0'.repeat(64)}`;
const daemonID = '0f8e2c1a-4b6d-4e3f-9a7b-1c2d3e4f5a6b';
const address = '100.69.47.33:8415';
const token = 'x'.repeat(32);
const env = { ATC_GATEWAY_TOKEN_GEOFFCLOUD: token };

interface DaemonFields {
  readonly address?: string;
  readonly daemonID?: string;
}

// one daemon named geoffcloud, with the given fields
function buildConfig(daemon: DaemonFields) {
  return { image, daemons: { geoffcloud: daemon }, defaultDaemon: 'geoffcloud' };
}

const config = buildConfig({ address, daemonID });

describe('requireATCGatewayInputs', () => {
  test('returns each daemon with its token, and the default, when every input is set', () => {
    expect(requireATCGatewayInputs(config, env)).toEqual({
      daemons: { geoffcloud: { address, daemonID, token } },
      defaultDaemon: 'geoffcloud',
    });
  });

  test('takes several daemons, each with the token atc derives from its name', () => {
    const homePC = { address: '100.67.122.120:8415', daemonID: daemonID.replace('0f8e', '1a2b') };
    const homeToken = 'y'.repeat(32);

    const checked = requireATCGatewayInputs(
      {
        image,
        daemons: { geoffcloud: { address, daemonID }, 'home-pc': homePC },
        defaultDaemon: 'geoffcloud',
      },
      { ...env, ATC_GATEWAY_TOKEN_HOME_PC: homeToken },
    );

    expect(checked.daemons).toEqual({
      geoffcloud: { address, daemonID, token },
      'home-pc': { ...homePC, token: homeToken },
    });
  });

  test('refuses the fixture stand-in image', () => {
    const standIn =
      'ghcr.io/zgeoff/atc-gateway:2.10.0@sha256:86cd2af8f297cb5143cee19e71b921d6ba0bc3e3a004d6498be7533b34a068be';

    expect(() => requireATCGatewayInputs({ ...config, image: standIn }, env)).toThrow(
      'fixture stand-in',
    );

    expect(() =>
      requireATCGatewayInputs({ ...config, image: 'ghcr.io/zgeoff/atc-gateway:2.10.0' }, env),
    ).toThrow('fixture stand-in');
  });
});

describe('requireATCGatewayInputs daemons', () => {
  test('refuses no daemons, naming the fields they replace', () => {
    expect(() => requireATCGatewayInputs({ image, defaultDaemon: 'geoffcloud' }, env)).toThrow(
      'atcGateway.daemons is unset or empty',
    );

    expect(() =>
      requireATCGatewayInputs({ image, daemons: {}, defaultDaemon: 'geoffcloud' }, env),
    ).toThrow('they replace atcGateway.daemonAddress and daemonID');
  });

  test('refuses a name that is not a lowercase DNS label atc takes', () => {
    for (const name of ['GeoffCloud', 'home_pc', '1pc', 'pc-', 'home.pc', 'a'.repeat(32)]) {
      expect(() =>
        requireATCGatewayInputs(
          { image, daemons: { [name]: { address, daemonID } }, defaultDaemon: name },
          {},
        ),
      ).toThrow(`atcGateway.daemons.${name}: a daemon name must be a lowercase DNS label`);
    }

    expect(
      requireATCGatewayInputs(
        {
          image,
          daemons: { [`a${'1'.repeat(30)}`]: { address, daemonID } },
          defaultDaemon: `a${'1'.repeat(30)}`,
        },
        { [`ATC_GATEWAY_TOKEN_A${'1'.repeat(30)}`]: token },
      ).defaultDaemon,
    ).toBe(`a${'1'.repeat(30)}`);
  });

  test('refuses a defaultDaemon that is unset or not among the daemons', () => {
    expect(() => requireATCGatewayInputs({ image, daemons: config.daemons }, env)).toThrow(
      'atcGateway.defaultDaemon is unset: name the daemon a call without one goes to, one of geoffcloud',
    );

    expect(() => requireATCGatewayInputs({ ...config, defaultDaemon: 'home-pc' }, env)).toThrow(
      "atcGateway.defaultDaemon 'home-pc' is not in atcGateway.daemons (geoffcloud)",
    );
  });
});

describe('requireATCGatewayInputs daemon', () => {
  test('refuses to deploy without a pinned daemonID', () => {
    expect(() => requireATCGatewayInputs(buildConfig({ address }), env)).toThrow(
      'atcGateway.daemons.geoffcloud.daemonID is unset',
    );

    expect(() => requireATCGatewayInputs(buildConfig({ address, daemonID: '' }), env)).toThrow(
      'atcGateway.daemons.geoffcloud.daemonID is unset',
    );
  });

  test('refuses a daemonID that is not a lowercase UUID', () => {
    for (const bad of [daemonID.toUpperCase(), 'geoffcloud']) {
      expect(() => requireATCGatewayInputs(buildConfig({ address, daemonID: bad }), env)).toThrow(
        'lowercase UUID',
      );
    }
  });

  test('refuses a missing or malformed daemon address', () => {
    expect(() => requireATCGatewayInputs(buildConfig({ daemonID }), env)).toThrow(
      'atcGateway.daemons.geoffcloud.address',
    );

    for (const bad of ['100.69.47.33', '100.69.47.33:0', '100.69.47.33:65536']) {
      expect(() => requireATCGatewayInputs(buildConfig({ address: bad, daemonID }), env)).toThrow(
        'atcGateway.daemons.geoffcloud.address',
      );
    }

    for (const good of ['100.69.47.33:65535', '[fd7a::1]:8415']) {
      expect(
        requireATCGatewayInputs(buildConfig({ address: good, daemonID }), env).daemons['geoffcloud']
          ?.address,
      ).toBe(good);
    }
  });
});

describe('requireATCGatewayInputs token', () => {
  test('refuses a missing, padded or short token, without echoing it', () => {
    expect(() => requireATCGatewayInputs(config, {})).toThrow(
      'ATC_GATEWAY_TOKEN_GEOFFCLOUD is empty',
    );

    expect(() => requireATCGatewayInputs(config, { ATC_GATEWAY_TOKEN_GEOFFCLOUD: '' })).toThrow(
      'ATC_GATEWAY_TOKEN_GEOFFCLOUD is empty',
    );

    for (const padded of [`${token}\n`, `${token}\n${token}`]) {
      expect(() =>
        requireATCGatewayInputs(config, { ATC_GATEWAY_TOKEN_GEOFFCLOUD: padded }),
      ).toThrow('no whitespace');
    }

    expect(() =>
      requireATCGatewayInputs(config, { ATC_GATEWAY_TOKEN_GEOFFCLOUD: 'short-secret-value' }),
    ).toThrow(/^ATC_GATEWAY_TOKEN_GEOFFCLOUD is shorter than 32 bytes$/u);
  });

  test("checks each daemon's own token variable", () => {
    const homePC = { address: '100.67.122.120:8415', daemonID };

    expect(() =>
      requireATCGatewayInputs(
        {
          image,
          daemons: { geoffcloud: { address, daemonID }, 'home-pc': homePC },
          defaultDaemon: 'geoffcloud',
        },
        env,
      ),
    ).toThrow('ATC_GATEWAY_TOKEN_HOME_PC is empty');
  });
});
