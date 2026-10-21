import { expect, test } from 'bun:test';
import { buildMockBumpPullRequest } from '../test-utils/build-mock-bump-pull-request.ts';
import { decide } from './decide.ts';

test('it merges a green atc bump at its head', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    head: '1111111111111111111111111111111111111111',
    labels: ['update:minor', 'auto-merge'],
    files: [
      'images/atc-gateway/versions.env',
      'images/agent/Dockerfile',
      'nixos/packages/atc.nix',
      'scripts/release/release-pins.json',
    ],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [
      { workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' },
      { workflow: 'release bump merge', name: 'merge', status: 'COMPLETED', conclusion: 'SKIPPED' },
    ],
  });

  expect(
    decide({ branch: 'release-check/atc', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({ action: 'merge', number: 7, head: '1111111111111111111111111111111111111111' });
});

test('it merges an imp bump that no nixos checks run covers', () => {
  const pr = buildMockBumpPullRequest({
    number: 9,
    authorLogin: 'app/cloud-release-check',
    head: '2222222222222222222222222222222222222222',
    labels: ['update:patch', 'auto-merge'],
    files: [
      'images/agent/Dockerfile',
      'nixos/flake.lock',
      'nixos/flake.nix',
      'nixos/hosts/geoffcloud/configuration.nix',
      'scripts/release/release-pins.json',
    ],
    commits: [
      {
        oid: '2222222222222222222222222222222222222222',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/imp', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({ action: 'merge', number: 9, head: '2222222222222222222222222222222222222222' });
});

test('it merges a nixie bump once CI passed', () => {
  const pr = buildMockBumpPullRequest({
    number: 11,
    authorLogin: 'app/cloud-release-check',
    head: '3333333333333333333333333333333333333333',
    labels: ['update:patch', 'auto-merge'],
    files: ['infra/Pulumi.prod.yaml', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '3333333333333333333333333333333333333333',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/nixie', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({
    action: 'merge',
    number: 11,
    head: '3333333333333333333333333333333333333333',
  });
});

test('it merges a gateway image bump once CI passed', () => {
  const pr = buildMockBumpPullRequest({
    number: 14,
    authorLogin: 'app/cloud-release-check',
    head: '5555555555555555555555555555555555555555',
    labels: ['update:minor', 'auto-merge'],
    files: ['infra/Pulumi.prod.yaml', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '5555555555555555555555555555555555555555',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({
      branch: 'release-check/atc-gateway-images',
      appLogin: 'app/cloud-release-check',
      pr,
    }),
  ).toStrictEqual({
    action: 'merge',
    number: 14,
    head: '5555555555555555555555555555555555555555',
  });
});

test('it holds a gateway image bump that changes the image pins file', () => {
  const pr = buildMockBumpPullRequest({
    number: 15,
    authorLogin: 'app/cloud-release-check',
    head: '6666666666666666666666666666666666666666',
    labels: ['update:minor', 'auto-merge'],
    files: [
      'images/atc-gateway/versions.env',
      'infra/Pulumi.prod.yaml',
      'scripts/release/release-pins.json',
    ],
    commits: [
      {
        oid: '6666666666666666666666666666666666666666',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({
      branch: 'release-check/atc-gateway-images',
      appLogin: 'app/cloud-release-check',
      pr,
    }),
  ).toStrictEqual({
    action: 'hold',
    number: 15,
    reason: 'it changes images/atc-gateway/versions.env, which no pin of its dependency writes',
  });
});

test('it merges an auto-mode bump that changes only the agent image', () => {
  const pr = buildMockBumpPullRequest({
    number: 8,
    authorLogin: 'app/cloud-release-check',
    head: '4444444444444444444444444444444444444444',
    labels: ['update:patch', 'auto-merge'],
    files: ['images/agent/Dockerfile', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '4444444444444444444444444444444444444444',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [
      { workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' },
      { workflow: 'release bump merge', name: 'merge', status: 'COMPLETED', conclusion: 'NEUTRAL' },
    ],
  });

  expect(
    decide({ branch: 'release-check/auto-mode', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({ action: 'merge', number: 8, head: '4444444444444444444444444444444444444444' });
});

test('it holds a bump that does not update the pin table', () => {
  const pr = buildMockBumpPullRequest({
    number: 12,
    authorLogin: 'app/cloud-release-check',
    head: '5555555555555555555555555555555555555555',
    labels: ['update:patch', 'auto-merge'],
    files: ['images/agent/Dockerfile'],
    commits: [
      {
        oid: '5555555555555555555555555555555555555555',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/auto-mode', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({
    action: 'hold',
    number: 12,
    reason: 'it does not update scripts/release/release-pins.json',
  });
});

test('it skips a branch that is not a release check branch', () => {
  expect(
    decide({
      branch: 'release-check/renovate',
      appLogin: 'app/cloud-release-check',
      pr: buildMockBumpPullRequest(),
    }),
  ).toStrictEqual({
    action: 'skip',
    reason: 'release-check/renovate is not a release check branch',
  });
});

test('it skips a release check branch without an open pull request', () => {
  expect(
    decide({ branch: 'release-check/atc', appLogin: 'app/cloud-release-check', pr: undefined }),
  ).toStrictEqual({ action: 'skip', reason: 'release-check/atc has no open pull request' });
});

test('it holds a pull request that another author opened', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'someone',
    labels: ['update:patch', 'auto-merge'],
    files: ['images/agent/Dockerfile', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/atc', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({
    action: 'hold',
    number: 7,
    reason: 'app/cloud-release-check did not open it from zgeoff/cloud',
  });
});

test('it holds a pull request from another repository', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    isCrossRepository: true,
    labels: ['update:patch', 'auto-merge'],
    files: ['images/agent/Dockerfile', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/atc', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({
    action: 'hold',
    number: 7,
    reason: 'app/cloud-release-check did not open it from zgeoff/cloud',
  });
});

test('it holds a pull request with a commit that another author pushed', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    labels: ['update:patch', 'auto-merge'],
    files: ['images/agent/Dockerfile', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
      {
        oid: '2222222222222222222222222222222222222222',
        authorLogins: ['cloud-release-check[bot]', 'someone'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/atc', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({
    action: 'hold',
    number: 7,
    reason: 'commits 2222222 are not all by cloud-release-check[bot]',
  });
});

test('it holds a pull request without a commit', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    labels: ['update:patch', 'auto-merge'],
    files: ['images/agent/Dockerfile', 'scripts/release/release-pins.json'],
    commits: [],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/atc', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({
    action: 'hold',
    number: 7,
    reason: 'commits none are not all by cloud-release-check[bot]',
  });
});

test('it holds a pull request labelled needs-review beside auto-merge', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    labels: ['update:patch', 'auto-merge', 'needs-review'],
    files: ['images/agent/Dockerfile', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/atc', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({
    action: 'hold',
    number: 7,
    reason: 'it is not labelled auto-merge without needs-review',
  });
});

test('it holds a pull request without the auto-merge label', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    labels: ['update:major'],
    files: ['images/agent/Dockerfile', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/atc', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({
    action: 'hold',
    number: 7,
    reason: 'it is not labelled auto-merge without needs-review',
  });
});

test('it holds an auto-mode bump that changes a file outside the agent image', () => {
  const pr = buildMockBumpPullRequest({
    number: 8,
    authorLogin: 'app/cloud-release-check',
    labels: ['update:patch', 'auto-merge'],
    files: ['images/agent/Dockerfile', 'nixos/packages/atc.nix'],
    commits: [
      {
        oid: '2222222222222222222222222222222222222222',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/auto-mode', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({
    action: 'hold',
    number: 8,
    reason: 'it changes nixos/packages/atc.nix, which no pin of its dependency writes',
  });
});

test('it names every file outside the pins in sorted order', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    labels: ['update:patch', 'auto-merge'],
    files: ['scripts/release/release-registry.ts', 'infra/Pulumi.prod.yaml', 'docs/nixie.md'],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SUCCESS' }],
  });

  expect(
    decide({ branch: 'release-check/nixie', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({
    action: 'hold',
    number: 7,
    reason:
      'it changes docs/nixie.md scripts/release/release-registry.ts, which no pin of its dependency writes',
  });
});

test('it holds a pull request while a check is pending', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    labels: ['update:patch', 'auto-merge'],
    files: ['images/agent/Dockerfile', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [
      { workflow: 'CI', name: 'checks', status: 'IN_PROGRESS', conclusion: null },
      { workflow: 'CI', name: 'auto-merge', status: 'QUEUED', conclusion: null },
    ],
  });

  expect(
    decide({ branch: 'release-check/atc', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({ action: 'hold', number: 7, reason: 'waiting for checks, auto-merge' });
});

test('it holds a pull request whose check failed and names it', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    labels: ['update:patch', 'auto-merge'],
    files: ['images/agent/Dockerfile', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'FAILURE' }],
  });

  expect(
    decide({ branch: 'release-check/atc', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({ action: 'hold', number: 7, reason: 'checks (FAILURE) did not pass' });
});

test('it waits for checks before CI registers its check', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    labels: ['update:patch', 'auto-merge'],
    files: ['infra/Pulumi.prod.yaml', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [],
  });

  expect(
    decide({ branch: 'release-check/nixie', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({ action: 'hold', number: 7, reason: 'waiting for checks (CI)' });
});

test('it waits for a required check that was skipped', () => {
  const pr = buildMockBumpPullRequest({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    labels: ['update:patch', 'auto-merge'],
    files: ['infra/Pulumi.prod.yaml', 'scripts/release/release-pins.json'],
    commits: [
      {
        oid: '1111111111111111111111111111111111111111',
        authorLogins: ['cloud-release-check[bot]'],
      },
    ],
    checkRuns: [{ workflow: 'CI', name: 'checks', status: 'COMPLETED', conclusion: 'SKIPPED' }],
  });

  expect(
    decide({ branch: 'release-check/nixie', appLogin: 'app/cloud-release-check', pr }),
  ).toStrictEqual({ action: 'hold', number: 7, reason: 'waiting for checks (CI)' });
});
