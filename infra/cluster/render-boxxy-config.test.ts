import { expect, test } from 'bun:test';
import { renderBoxxyConfig } from './render-boxxy-config.ts';

function setupTest() {
  const config = {
    runner: 'runner-for-tests',
    atc: {
      trustedFolders: { 'target-for-tests': ['/workspace'] },
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

test("it puts the public door on its port, with the stack config's URL and trusted peers, and leaves the address and the auth file to the server's defaults", () => {
  const fixture = setupTest();

  expect(
    JSON.parse(
      renderBoxxyConfig({
        config: {
          ...fixture.config,
          publicDoor: { publicURL: 'https://boxxy.example.com', trustForwardedFrom: ['127.0.0.1'] },
        },
        repos: fixture.repos,
        atc: {
          url: 'http://atc-gateway.atc.svc.cluster.local:8414/mcp',
          host: 'atc.fixture.invalid',
        },
        trusted: false,
      }),
    ),
  ).toMatchObject({
    publicDoor: {
      port: 8092,
      publicURL: 'https://boxxy.example.com',
      trustForwardedFrom: ['127.0.0.1'],
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

test('it writes the pepys section it is given and the GitHub root of the config', () => {
  const fixture = setupTest();

  const pepys = {
    ingestUrl: 'http://pepys-ingest.fixture.invalid:8080/boxxy/facts',
    apiUrl: 'http://pepys-host.fixture.invalid:8081/rpc',
    environment: 'production',
  };

  expect(
    JSON.parse(
      renderBoxxyConfig({
        config: { ...fixture.config, github: { baseUrl: 'https://api.github.com' } },
        repos: fixture.repos,
        atc: {
          url: 'http://atc-gateway.atc.svc.cluster.local:8414/mcp',
          host: 'atc.fixture.invalid',
        },
        pepys,
        trusted: false,
      }),
    ),
  ).toMatchObject({ pepys, github: { baseUrl: 'https://api.github.com' } });
});
