import { expect, test } from 'bun:test';
import { buildAgentImageGuestScript } from './build-agent-image-guest-script.ts';

test('it leads the checks with each version pin as a shell assignment, then the mode', () => {
  const script = buildAgentImageGuestScript({
    pins: new Map([
      ['UBUNTU_SNAPSHOT', '20261006T000000Z'],
      ['GIT_VERSION', '1:2.43.0-1ubuntu7.3'],
      ['BUN_VERSION', '1.4.2'],
      ['BUN_SHA256', '36368f'],
    ]),
    mode: 'imp',
    body: 'echo "== $failures failed"\n',
  });

  expect(script).toBe(
    "GIT_VERSION='1:2.43.0-1ubuntu7.3'\nBUN_VERSION='1.4.2'\ncheck_mode='imp'\necho \"== $failures failed\"\n",
  );
});

test('it quotes a pin that holds a quote, so bash assigns it whole', () => {
  const script = buildAgentImageGuestScript({
    pins: new Map([['ODD_VERSION', "1'2"]]),
    mode: 'docker',
    body: '',
  });

  expect(script).toBe("ODD_VERSION='1'\\''2'\ncheck_mode='docker'\n");
});
