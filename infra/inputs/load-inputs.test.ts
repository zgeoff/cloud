import { expect, test } from 'bun:test';
import { Output } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { buildStubConfig } from '../test-utils/build-stub-config.ts';
import { loadInputs } from './load-inputs.ts';

test('it returns the account ID, hostOnTailnet off and no alert URL or cluster for a bare stack', () => {
  expect(
    loadInputs(buildStubConfig({ cluster: 'none' }), {
      CLOUDFLARE_ACCOUNT_ID: '0123456789abcdef0123456789abcdef',
    }),
  ).toStrictEqual({
    accountID: '0123456789abcdef0123456789abcdef',
    hostOnTailnet: false,
    alertURL: undefined,
  });
});

test('it reads hostOnTailnet from the stack config', () => {
  expect(
    loadInputs(buildStubConfig({ cluster: 'none', hostOnTailnet: 'true' }), {
      CLOUDFLARE_ACCOUNT_ID: '0123456789abcdef0123456789abcdef',
    }).hostOnTailnet,
  ).toBeTrue();
});

test('it throws a clear error when CLOUDFLARE_ACCOUNT_ID is blank', () => {
  expect(() =>
    loadInputs(buildStubConfig({ cluster: 'none' }), { CLOUDFLARE_ACCOUNT_ID: '' }),
  ).toThrowWithMessage(
    Error,
    'CLOUDFLARE_ACCOUNT_ID is blank; run through `op run --env-file=../.env`',
  );
});

test('it gives the health check and Alertmanager the same trimmed webhook URL, and Alertmanager the trimmed user to mention', () => {
  const inputs = loadInputs(buildStubConfig({ cluster: 'managed', discordAlerts: 'true' }), {
    CLOUDFLARE_ACCOUNT_ID: '0123456789abcdef0123456789abcdef',
    K3S_KUBECONFIG: 'apiVersion: v1',
    ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
    ALERT_WEBHOOK_URL: ' https://discord.com/api/webhooks/1/abc\n',
    ALERT_MENTION_USER_ID: ' 100000000000000001\n',
  });

  expect(inputs).toStrictEqual({
    accountID: '0123456789abcdef0123456789abcdef',
    hostOnTailnet: false,
    alertURL: 'https://discord.com/api/webhooks/1/abc',
    cluster: {
      kubeconfig: 'apiVersion: v1',
      onePasswordConnectCredentials: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
      alertWebhook: {
        url: 'https://discord.com/api/webhooks/1/abc',
        mentionUserID: '100000000000000001',
      },
    },
  });
});

test('it leaves Alertmanager without the webhook while discordAlerts is off', () => {
  const inputs = loadInputs(buildStubConfig({ cluster: 'managed' }), {
    CLOUDFLARE_ACCOUNT_ID: '0123456789abcdef0123456789abcdef',
    K3S_KUBECONFIG: 'apiVersion: v1',
    ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
    ALERT_WEBHOOK_URL: 'https://discord.com/api/webhooks/1/abc',
    ALERT_MENTION_USER_ID: '100000000000000001',
  });

  invariant(inputs.cluster);

  expect(inputs.cluster.alertWebhook).toBeUndefined();
});

test('it throws when discordAlerts is on for a managed cluster and the user to mention is blank', () => {
  expect(() =>
    loadInputs(buildStubConfig({ cluster: 'managed', discordAlerts: 'true' }), {
      CLOUDFLARE_ACCOUNT_ID: '0123456789abcdef0123456789abcdef',
      K3S_KUBECONFIG: 'apiVersion: v1',
      ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
      ALERT_WEBHOOK_URL: 'https://discord.com/api/webhooks/1/abc',
      ALERT_MENTION_USER_ID: ' ',
    }),
  ).toThrowWithMessage(
    Error,
    'discordAlerts is on, but ALERT_MENTION_USER_ID is empty; run through `op run --env-file=../.env`',
  );
});

test('it throws when discordAlerts is on for a managed cluster and the webhook is blank', () => {
  expect(() =>
    loadInputs(buildStubConfig({ cluster: 'managed', discordAlerts: 'true' }), {
      CLOUDFLARE_ACCOUNT_ID: '0123456789abcdef0123456789abcdef',
      K3S_KUBECONFIG: 'apiVersion: v1',
      ONEPASSWORD_CONNECT_CREDENTIALS: '{"verifier":{}}',
      ALERT_WEBHOOK_URL: ' ',
    }),
  ).toThrowWithMessage(
    Error,
    'discordAlerts is on, but ALERT_WEBHOOK_URL is empty; run through `op run --env-file=../.env`',
  );
});

test('it needs no webhook for discordAlerts while the stack leaves the cluster out', () => {
  expect(
    loadInputs(buildStubConfig({ cluster: 'none', discordAlerts: 'true' }), {
      CLOUDFLARE_ACCOUNT_ID: '0123456789abcdef0123456789abcdef',
    }),
  ).toStrictEqual({
    accountID: '0123456789abcdef0123456789abcdef',
    hostOnTailnet: false,
    alertURL: undefined,
  });
});
