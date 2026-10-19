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
      route: {
        hostname: 'atc.geoff.cloud',
        service: output('http://atc-gateway.atc.svc.cluster.local:8414'),
      },
      access: { teamName, audience },
      tunnelID: atcTunnelID,
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

  expect(buildTunnelRouteSpecs(sharedTunnelID, undefined)).toStrictEqual({
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
