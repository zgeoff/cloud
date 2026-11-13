import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildTunnelRouteSpecs } from './build-tunnel-route-specs.ts';

test("it points the gateway's CNAME at the atc tunnel and leaves the shared tunnel the preview webhook alone", () => {
  const sharedTunnelID = output('11111111-1111-4111-8111-111111111111');
  const atcTunnelID = output('22222222-2222-4222-8222-222222222222');
  const teamName = output('example-team');
  const audience = output('0123456789abcdef');

  expect(
    buildTunnelRouteSpecs(sharedTunnelID, {
      gateway: {
        hostname: 'atc.geoff.cloud',
        access: { teamName, audience },
        tunnelID: atcTunnelID,
      },
      files: undefined,
      pepys: undefined,
      pepysAPI: undefined,
    }),
  ).toStrictEqual({
    sharedIngresses: [
      {
        hostname: 'preview-webhook.geoff.cloud',
        path: '^/webhook$',
        service: 'http://100.69.47.33:8418',
      },
      { service: 'http_status:404' },
    ],
    previewWebhookRecord: { hostname: 'preview-webhook.geoff.cloud', tunnelID: sharedTunnelID },
    atc: {
      ingresses: [
        {
          hostname: 'atc.geoff.cloud',
          path: '^(?:/oauth2/authorize|/login|/enroll|/consent|/error)$',
          service: 'http://127.0.0.1:8414',
          originRequest: { access: { required: true, teamName, audTags: [audience] } },
        },
        {
          hostname: 'atc.geoff.cloud',
          path: String.raw`^(?:/|/mcp|/oauth2/token|/oauth2/revoke|/\.well-known/oauth-authorization-server|/\.well-known/oauth-protected-resource|/\.well-known/oauth-protected-resource/mcp)$`,
          service: 'http://127.0.0.1:8414',
        },
        { service: 'http_status:404' },
      ],
      record: { hostname: 'atc.geoff.cloud', tunnelID: atcTunnelID },
    },
  });
});

test('it routes only the preview webhook, on the shared tunnel, without the gateway', () => {
  const sharedTunnelID = output('11111111-1111-4111-8111-111111111111');

  expect(
    buildTunnelRouteSpecs(sharedTunnelID, {
      gateway: undefined,
      files: undefined,
      pepys: undefined,
      pepysAPI: undefined,
    }),
  ).toStrictEqual({
    sharedIngresses: [
      {
        hostname: 'preview-webhook.geoff.cloud',
        path: '^/webhook$',
        service: 'http://100.69.47.33:8418',
      },
      { service: 'http_status:404' },
    ],
    previewWebhookRecord: { hostname: 'preview-webhook.geoff.cloud', tunnelID: sharedTunnelID },
  });
});

test('it routes every path of the files host to the files service on the shared tunnel, before the catch-all', () => {
  const sharedTunnelID = output('11111111-1111-4111-8111-111111111111');
  const service = output('http://files.files.svc.cluster.local:8080');

  expect(
    buildTunnelRouteSpecs(sharedTunnelID, {
      gateway: undefined,
      files: { hostname: 'files.geoff.cloud', service },
      pepys: undefined,
      pepysAPI: undefined,
    }),
  ).toStrictEqual({
    sharedIngresses: [
      {
        hostname: 'preview-webhook.geoff.cloud',
        path: '^/webhook$',
        service: 'http://100.69.47.33:8418',
      },
      { hostname: 'files.geoff.cloud', service },
      { service: 'http_status:404' },
    ],
    previewWebhookRecord: { hostname: 'preview-webhook.geoff.cloud', tunnelID: sharedTunnelID },
    filesRecord: { hostname: 'files.geoff.cloud', tunnelID: sharedTunnelID },
  });
});

test('it refuses a files host that the exposure registry does not list as public', () => {
  expect(() =>
    buildTunnelRouteSpecs(output('11111111-1111-4111-8111-111111111111'), {
      gateway: undefined,
      files: {
        hostname: 'uploads.geoff.cloud',
        service: output('http://files.files.svc.cluster.local:8080'),
      },
      pepys: undefined,
      pepysAPI: undefined,
    }),
  ).toThrowWithMessage(
    Error,
    'tunnel hostname uploads.geoff.cloud is not in packages/topology/exposure.json; a route needs a public tunnel-hostname entry',
  );
});

test("it routes only pepys's public paths of its host to ingest on the shared tunnel, before the catch-all", () => {
  const sharedTunnelID = output('11111111-1111-4111-8111-111111111111');

  expect(
    buildTunnelRouteSpecs(sharedTunnelID, {
      gateway: undefined,
      files: undefined,
      pepys: {
        hostname: 'pepys-webhook.geoff.cloud',
        service: 'http://pepys-ingest.pepys.svc.cluster.local:8080',
        path: '^(?:/webhook/github)$',
      },
      pepysAPI: undefined,
    }),
  ).toStrictEqual({
    sharedIngresses: [
      {
        hostname: 'preview-webhook.geoff.cloud',
        path: '^/webhook$',
        service: 'http://100.69.47.33:8418',
      },
      {
        hostname: 'pepys-webhook.geoff.cloud',
        path: '^(?:/webhook/github)$',
        service: 'http://pepys-ingest.pepys.svc.cluster.local:8080',
      },
      { service: 'http_status:404' },
    ],
    previewWebhookRecord: { hostname: 'preview-webhook.geoff.cloud', tunnelID: sharedTunnelID },
    pepysRecord: { hostname: 'pepys-webhook.geoff.cloud', tunnelID: sharedTunnelID },
  });
});

test("it routes the pepys API's paths to the API on the shared tunnel, browser paths with Access, before the catch-all", () => {
  const sharedTunnelID = output('11111111-1111-4111-8111-111111111111');
  const teamName = output('example-team');
  const audience = output('0123456789abcdef');

  expect(
    buildTunnelRouteSpecs(sharedTunnelID, {
      gateway: undefined,
      files: undefined,
      pepys: undefined,
      pepysAPI: {
        route: {
          hostname: 'pepys.geoff.cloud',
          service: 'http://pepys-host.pepys.svc.cluster.local:8081',
        },
        access: { teamName, audience },
      },
    }),
  ).toStrictEqual({
    sharedIngresses: [
      {
        hostname: 'preview-webhook.geoff.cloud',
        path: '^/webhook$',
        service: 'http://100.69.47.33:8418',
      },
      {
        hostname: 'pepys.geoff.cloud',
        path: '^(?:/oauth2/authorize|/login|/enroll|/consent|/error)$',
        service: 'http://pepys-host.pepys.svc.cluster.local:8081',
        originRequest: { access: { required: true, teamName, audTags: [audience] } },
      },
      {
        hostname: 'pepys.geoff.cloud',
        path: String.raw`^(?:/|/mcp|/oauth2/token|/oauth2/revoke|/\.well-known/oauth-authorization-server|/\.well-known/oauth-protected-resource|/\.well-known/oauth-protected-resource/mcp)$`,
        service: 'http://pepys-host.pepys.svc.cluster.local:8081',
      },
      { service: 'http_status:404' },
    ],
    previewWebhookRecord: { hostname: 'preview-webhook.geoff.cloud', tunnelID: sharedTunnelID },
    pepysAPIRecord: { hostname: 'pepys.geoff.cloud', tunnelID: sharedTunnelID },
  });
});
