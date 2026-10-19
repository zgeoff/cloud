import { expect, test } from 'bun:test';
import { parseActionsWorkflow } from './parse-actions-workflow.ts';

test('it parses each job s needs, condition and concurrency, and the workflow s group', () => {
  expect(
    parseActionsWorkflow(`
concurrency: Deploy
jobs:
  build:
    runs-on: ubuntu-latest
  test:
    needs: build
    concurrency:
      group: Test
      queue: single
    runs-on: ubuntu-latest
  ship:
    needs: [build, test]
    if: github.event_name == 'push'
    concurrency:
      group: Ship
      cancel-in-progress: false
      queue: max
    runs-on: ubuntu-latest
`),
  ).toStrictEqual({
    concurrency: { group: 'deploy', queue: 'single' },
    jobs: [
      { name: 'build', needs: [], condition: undefined, concurrency: undefined, outputs: {} },
      {
        name: 'test',
        needs: ['build'],
        condition: undefined,
        concurrency: { group: 'test', queue: 'single' },
        outputs: {},
      },
      {
        name: 'ship',
        needs: ['build', 'test'],
        condition: "github.event_name == 'push'",
        concurrency: { group: 'ship', queue: 'max' },
        outputs: {},
      },
    ],
  });
});

test.each([
  [
    'a group expression',
    `concurrency: deploy-\${{ github.ref }}`,
    `unsupported concurrency group expression: deploy-\${{ github.ref }}`,
  ],
  [
    'cancel-in-progress',
    'concurrency:\n  group: deploy\n  cancel-in-progress: true',
    'unsupported concurrency: cancel-in-progress',
  ],
  [
    'a queue other than single or max',
    'concurrency:\n  group: deploy\n  queue: 25',
    'unsupported concurrency queue: 25',
  ],
  [
    'a concurrency with no group',
    'concurrency:\n  queue: single',
    'unsupported concurrency: {"queue":"single"}',
  ],
])('it rejects %s, which the stand-in does not model', (_label, concurrency, message) => {
  expect(() =>
    parseActionsWorkflow(`${concurrency}\njobs:\n  ship:\n    runs-on: ubuntu-latest\n`),
  ).toThrowWithMessage(Error, message);
});

test('it parses each job output that publishes a step s output', () => {
  expect(
    parseActionsWorkflow(`
jobs:
  ship:
    outputs:
      verdict: \${{ steps.guard.outputs.verdict }}
      ship-id: \${{steps.ship-it.outputs.id}}
    runs-on: ubuntu-latest
`).jobs,
  ).toStrictEqual([
    {
      name: 'ship',
      needs: [],
      condition: undefined,
      concurrency: undefined,
      outputs: {
        verdict: { step: 'guard', output: 'verdict' },
        'ship-id': { step: 'ship-it', output: 'id' },
      },
    },
  ]);
});

test.each([
  ['an output from another context', `\${{ needs.build.outputs.id }}`],
  ['an output built from two steps', `\${{ steps.a.outputs.id || steps.b.outputs.id }}`],
])('it rejects %s, which the stand-in does not model', (_label, output) => {
  expect(() =>
    parseActionsWorkflow(
      `jobs:\n  ship:\n    outputs:\n      id: '${output}'\n    runs-on: ubuntu-latest\n`,
    ),
  ).toThrowWithMessage(Error, `job ship: unsupported output id: ${JSON.stringify(output)}`);
});

test('it rejects a condition that is not a string', () => {
  expect(() =>
    parseActionsWorkflow('jobs:\n  ship:\n    if: true\n    runs-on: ubuntu-latest\n'),
  ).toThrowWithMessage(Error, 'job ship: unsupported if: true');
});

test('it rejects needs that are not job names', () => {
  expect(() =>
    parseActionsWorkflow('jobs:\n  ship:\n    needs: 3\n    runs-on: ubuntu-latest\n'),
  ).toThrowWithMessage(Error, 'job ship: unsupported needs: 3');
});

test('it rejects a job that is not a mapping', () => {
  expect(() => parseActionsWorkflow('jobs:\n  ship: yes\n')).toThrowWithMessage(
    Error,
    'job ship is not a mapping',
  );
});

test('it rejects a workflow with no jobs', () => {
  expect(() => parseActionsWorkflow('name: empty\n')).toThrowWithMessage(
    Error,
    'the workflow has no jobs',
  );
});
