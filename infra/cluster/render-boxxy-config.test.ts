import { expect, test } from 'bun:test';
import { renderBoxxyConfig } from './render-boxxy-config.ts';

function setupTest() {
  const config = {
    runner: 'runner-for-tests',
    atc: {
      trustedFolders: { 'target-for-tests': ['/workspace'] },
      noticeSession: 'owner-session',
    },
    spawn: {
      target: 'target-for-tests',
      repoPaths: { 'owner/repo': '/workspace/repo' },
    },
  };

  return config;
}

test('it sets the listeners, the store on the volume and the image rules, with no trustedIssuers section while no trust document is mounted', () => {
  const config = setupTest();

  expect(
    JSON.parse(
      renderBoxxyConfig({
        config,
        atcURL: 'http://atc-gateway.atc.svc.cluster.local:8414/rpc',
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
      repoPaths: { 'owner/repo': '/workspace/repo' },
    },
    atc: {
      url: 'http://atc-gateway.atc.svc.cluster.local:8414/rpc',
      trustedFolders: { 'target-for-tests': ['/workspace'] },
      noticeSession: 'owner-session',
    },
  });
});

test("it names the mounted issuers folder and the broker's host as the audience when a trust document is mounted", () => {
  const config = setupTest();

  expect(
    JSON.parse(
      renderBoxxyConfig({
        config,
        atcURL: 'http://atc-gateway.atc.svc.cluster.local:8414/rpc',
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
  const config = setupTest();

  expect(
    renderBoxxyConfig({
      config,
      atcURL: 'http://atc-gateway.atc.svc.cluster.local:8414/rpc',
      trusted: false,
    }),
  ).toEndWith('}\n');
});
