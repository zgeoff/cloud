import { expect, test } from 'bun:test';
import { renderBoxxyConfig } from './render-boxxy-config.ts';

function setupTest() {
  const config = {
    runner: 'runner-for-tests',
    atc: {
      trustedFolders: { 'target-for-tests': ['/workspace'] },
      noticeSession: 'owner-session',
    },
    spawn: { target: 'target-for-tests' },
  };

  const repos = { 'owner/repo': { url: 'https://github.com/owner/repo', ref: 'main' } };

  return { config, repos };
}

test('it sets the listeners, the store on the volume, the image rules and the gateway address with its public host, with no trustedIssuers section while no trust document is mounted', () => {
  const fixture = setupTest();

  expect(
    JSON.parse(
      renderBoxxyConfig({
        config: fixture.config,
        repos: fixture.repos,
        atc: {
          url: 'http://atc-gateway.atc.svc.cluster.local:8414/mcp',
          host: 'atc.fixture.invalid',
        },
        trusted: false,
      }),
    ),
  ).toStrictEqual({
    runner: 'runner-for-tests',
    store: { file: '/data/boxxy.db' },
    rules: { folder: '/rules' },
    api: {
      listen: { hostname: '0.0.0.0', port: 8090 },
      workerListen: { hostname: '0.0.0.0', port: 8091 },
    },
    spawn: {
      target: 'target-for-tests',
      repos: { 'owner/repo': { url: 'https://github.com/owner/repo', ref: 'main' } },
    },
    atc: {
      url: 'http://atc-gateway.atc.svc.cluster.local:8414/mcp',
      host: 'atc.fixture.invalid',
      trustedFolders: { 'target-for-tests': ['/workspace'] },
      noticeSession: 'owner-session',
    },
  });
});

test("it names the mounted issuers folder and the broker's host as the audience when a trust document is mounted", () => {
  const fixture = setupTest();

  expect(
    JSON.parse(
      renderBoxxyConfig({
        config: fixture.config,
        repos: fixture.repos,
        atc: {
          url: 'http://atc-gateway.atc.svc.cluster.local:8414/mcp',
          host: 'atc.fixture.invalid',
        },
        trusted: true,
      }),
    ),
  ).toMatchObject({
    trustedIssuers: {
      folders: ['/etc/boxxy-issuers'],
      audience: 'boxxy.imp.internal',
    },
  });
});

test('it ends the file with one newline', () => {
  const fixture = setupTest();

  expect(
    renderBoxxyConfig({
      config: fixture.config,
      repos: fixture.repos,
      atc: {
        url: 'http://atc-gateway.atc.svc.cluster.local:8414/mcp',
        host: 'atc.fixture.invalid',
      },
      trusted: false,
    }),
  ).toEndWith('}\n');
});
