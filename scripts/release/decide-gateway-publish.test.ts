import { expect, test } from 'bun:test';
import { decideGatewayPublish } from './decide-gateway-publish.ts';

test.each([
  [
    'a pull request that changes the pins',
    {
      eventName: 'pull_request',
      ref: 'refs/pull/412/merge',
      pushInput: '',
      changedFiles: ['images/atc-gateway/versions.env'],
    },
    { action: 'skip', reason: 'refs/pull/412/merge is not main, and only main publishes' },
  ],
  [
    'a push to another branch that changes the pins',
    {
      eventName: 'push',
      ref: 'refs/heads/geo-31-gateway',
      pushInput: '',
      changedFiles: ['images/atc-gateway/versions.env'],
    },
    { action: 'skip', reason: 'refs/heads/geo-31-gateway is not main, and only main publishes' },
  ],
  [
    'a manual run with push: true on another branch',
    {
      eventName: 'workflow_dispatch',
      ref: 'refs/heads/geo-31-gateway',
      pushInput: 'true',
      changedFiles: [],
    },
    { action: 'skip', reason: 'refs/heads/geo-31-gateway is not main, and only main publishes' },
  ],
  [
    'a push to main that changes the pins',
    {
      eventName: 'push',
      ref: 'refs/heads/main',
      pushInput: '',
      changedFiles: ['images/atc-gateway/versions.env', 'scripts/release/release-pins.json'],
    },
    { action: 'publish', reason: 'the push to main changes images/atc-gateway/versions.env' },
  ],
  [
    'a push to main that changes only the image test',
    {
      eventName: 'push',
      ref: 'refs/heads/main',
      pushInput: '',
      changedFiles: ['images/atc-gateway/test-atc-gateway-image.sh'],
    },
    {
      action: 'skip',
      reason: 'the push to main leaves images/atc-gateway/versions.env as it was',
    },
  ],
  [
    'a manual run with push: true on main',
    { eventName: 'workflow_dispatch', ref: 'refs/heads/main', pushInput: 'true', changedFiles: [] },
    { action: 'publish', reason: 'a manual run on main asked to push' },
  ],
  [
    'a manual run without push: true on main',
    {
      eventName: 'workflow_dispatch',
      ref: 'refs/heads/main',
      pushInput: 'false',
      changedFiles: [],
    },
    { action: 'skip', reason: 'a manual run without push: true only tests the images' },
  ],
  [
    'a scheduled run on main',
    {
      eventName: 'schedule',
      ref: 'refs/heads/main',
      pushInput: '',
      changedFiles: ['images/atc-gateway/versions.env'],
    },
    { action: 'skip', reason: 'a schedule event never publishes' },
  ],
] as const)('it decides %s', (_label, input, decision) => {
  expect(decideGatewayPublish(input)).toStrictEqual(decision);
});
