import { expect, test } from 'bun:test';
import { isWorkflowTriggered } from './is-workflow-triggered.ts';

test.each([
  ['on: pull_request\n', true],
  ['on: [push, pull_request]\n', true],
  ['on:\n  pull_request:\n', true],
  ['on:\n  push:\n    branches: [main]\n', false],
  ['on:\n  pull_request:\n    branches: [main]\n', true],
  ["on:\n  pull_request:\n    branches: ['release/*']\n", false],
  ["on:\n  pull_request:\n    paths: ['nixos/**']\n", true],
  ["on:\n  pull_request:\n    paths: ['nixos/*']\n", false],
  ["on:\n  pull_request:\n    paths: ['images/**']\n", false],
])(
  'it answers %p for a pull request into main that changes nixos/hosts/geoffcloud/configuration.nix',
  (workflowText, triggered) => {
    expect(
      isWorkflowTriggered(workflowText, {
        name: 'pull_request',
        baseBranch: 'main',
        files: ['nixos/hosts/geoffcloud/configuration.nix'],
      }),
    ).toBe(triggered);
  },
);

test.each([
  ["on:\n  schedule:\n    - cron: '17 3 * * *'\n", true],
  ['on:\n  workflow_dispatch:\n', false],
])('it answers %p for a scheduled event', (workflowText, triggered) => {
  expect(isWorkflowTriggered(workflowText, { name: 'schedule' })).toBe(triggered);
});

test.each([
  ['on:\n  workflow_dispatch:\n', true],
  ["on:\n  schedule:\n    - cron: '17 3 * * *'\n", false],
])('it answers %p for a dispatch', (workflowText, triggered) => {
  expect(isWorkflowTriggered(workflowText, { name: 'workflow_dispatch' })).toBe(triggered);
});

test.each([
  ['on:\n  workflow_run:\n    workflows: [CI]\n', 'completed', 'renovate/example', true],
  ['on:\n  workflow_run:\n    workflows: [CI]\n', 'in_progress', 'renovate/example', false],
  ['on:\n  workflow_run:\n    workflows: [Lint]\n', 'completed', 'renovate/example', false],
  [
    "on:\n  workflow_run:\n    workflows: [CI]\n    types: [completed]\n    branches: ['release-check/**']\n",
    'completed',
    'release-check/imp',
    true,
  ],
  [
    "on:\n  workflow_run:\n    workflows: [CI]\n    types: [completed]\n    branches: ['release-check/**']\n",
    'completed',
    'renovate/example',
    false,
  ],
  [
    'on:\n  workflow_run:\n    workflows: [CI]\n    types: [requested]\n',
    'completed',
    'release-check/imp',
    false,
  ],
] as const)(
  'it answers %p for a %s CI run on %s with %p',
  (workflowText, type, headBranch, triggered) => {
    expect(
      isWorkflowTriggered(workflowText, { name: 'workflow_run', workflow: 'CI', type, headBranch }),
    ).toBe(triggered);
  },
);

test.each([
  ['jobs: {}\n', 'the workflow has no on'],
  [
    "on:\n  pull_request:\n    paths-ignore: ['docs/**']\n",
    'unsupported filter: on.pull_request.paths-ignore',
  ],
  ['on:\n  pull_request:\n    types: [labeled]\n', 'unsupported filter: on.pull_request.types'],
  ["on:\n  pull_request:\n    paths: ['!docs/**']\n", 'unsupported negated pattern: !docs/**'],
  ['on:\n  pull_request:\n    paths: docs\n', 'unsupported on.pull_request.paths: "docs"'],
  ['on: 3\n', 'unsupported on: 3'],
])('it refuses %p with %p', (workflowText, message) => {
  expect(() =>
    isWorkflowTriggered(workflowText, { name: 'pull_request', baseBranch: 'main', files: [] }),
  ).toThrowWithMessage(Error, message);
});
