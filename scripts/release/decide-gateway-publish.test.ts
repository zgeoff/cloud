import { expect, test } from 'bun:test';
import { decideGatewayPublish } from './decide-gateway-publish.ts';

test.each([
  [
    'a pull request',
    { eventName: 'pull_request', ref: 'refs/pull/412/merge', pushInput: '', pinnedImages: [] },
    { action: 'skip', reason: 'refs/pull/412/merge is not main, and only main publishes' },
  ],
  [
    'a push to another branch whose pinned tag is missing',
    {
      eventName: 'push',
      ref: 'refs/heads/geo-31-gateway',
      pushInput: '',
      pinnedImages: [{ reference: 'ghcr.io/zgeoff/atc-gateway:7.2.0', answer: { missing: true } }],
    },
    { action: 'skip', reason: 'refs/heads/geo-31-gateway is not main, and only main publishes' },
  ],
  [
    'a manual run with push: true on another branch',
    {
      eventName: 'workflow_dispatch',
      ref: 'refs/heads/geo-31-gateway',
      pushInput: 'true',
      pinnedImages: [],
    },
    { action: 'skip', reason: 'refs/heads/geo-31-gateway is not main, and only main publishes' },
  ],
  [
    'a push to main whose gateway tag the registry lacks',
    {
      eventName: 'push',
      ref: 'refs/heads/main',
      pushInput: '',
      pinnedImages: [
        { reference: 'ghcr.io/zgeoff/atc-gateway:7.2.0', answer: { missing: true } },
        {
          reference: 'ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2',
          answer: { digest: `sha256:${'3'.repeat(64)}` },
        },
      ],
    },
    { action: 'publish', reason: 'the registry lacks ghcr.io/zgeoff/atc-gateway:7.2.0' },
  ],
  [
    'a push to main whose two tags the registry lacks',
    {
      eventName: 'push',
      ref: 'refs/heads/main',
      pushInput: '',
      pinnedImages: [
        { reference: 'ghcr.io/zgeoff/atc-gateway:7.2.0', answer: { missing: true } },
        { reference: 'ghcr.io/zgeoff/atc-gateway-backup:2.25.0-r1', answer: { missing: true } },
      ],
    },
    {
      action: 'publish',
      reason:
        'the registry lacks ghcr.io/zgeoff/atc-gateway:7.2.0 and ghcr.io/zgeoff/atc-gateway-backup:2.25.0-r1',
    },
  ],
  [
    'a push to main whose tags the registry holds',
    {
      eventName: 'push',
      ref: 'refs/heads/main',
      pushInput: '',
      pinnedImages: [
        {
          reference: 'ghcr.io/zgeoff/atc-gateway:7.1.0',
          answer: { digest: `sha256:${'2'.repeat(64)}` },
        },
        {
          reference: 'ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2',
          answer: { digest: `sha256:${'3'.repeat(64)}` },
        },
      ],
    },
    { action: 'skip', reason: 'the registry holds every pinned tag' },
  ],
  [
    'a push to main whose tag lookup failed',
    {
      eventName: 'push',
      ref: 'refs/heads/main',
      pushInput: '',
      pinnedImages: [
        { reference: 'ghcr.io/zgeoff/atc-gateway:7.2.0', answer: { missing: true } },
        {
          reference: 'ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2',
          answer: { error: 'the registry answered 503' },
        },
      ],
    },
    {
      action: 'unknown',
      reason:
        'cannot tell whether a pinned tag is published: ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2 (the registry answered 503)',
    },
  ],
  [
    'a manual run with push: true on main',
    { eventName: 'workflow_dispatch', ref: 'refs/heads/main', pushInput: 'true', pinnedImages: [] },
    { action: 'publish', reason: 'a manual run on main asked to push' },
  ],
  [
    'a manual run without push: true on main',
    {
      eventName: 'workflow_dispatch',
      ref: 'refs/heads/main',
      pushInput: 'false',
      pinnedImages: [],
    },
    { action: 'skip', reason: 'a manual run without push: true only tests the images' },
  ],
  [
    'a scheduled run on main',
    { eventName: 'schedule', ref: 'refs/heads/main', pushInput: '', pinnedImages: [] },
    { action: 'skip', reason: 'a schedule event never publishes' },
  ],
] as const)('it decides %s', (_label, input, decision) => {
  expect(decideGatewayPublish(input)).toStrictEqual(decision);
});
