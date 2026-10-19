import { expect, test } from 'bun:test';
import { renderActionsTemplate } from './render-actions-template.ts';

test.each([
  [`\${{ github.event_name }}`, 'workflow_run'],
  [`\${{ github.event.workflow_run.head_sha }}`, 'abc123'],
  [`\${{github.sha}}`, 'def456'],
  [`\${{ inputs.revision }}`, 'abc123'],
  [`\${{ steps.guard.outputs.verdict }}`, 'hold'],
  [`\${{ steps.missing.outputs.verdict }}`, ''],
  [`\${{ inputs.absent }}`, ''],
  [`deploy \${{ github.event_name }} at \${{ github.sha }}`, 'deploy workflow_run at def456'],
  ['bun run up', 'bun run up'],
  [0, '0'],
  [true, 'true'],
])('it renders %p as %p', (value, rendered) => {
  expect(
    renderActionsTemplate(value, {
      github: {
        event_name: 'workflow_run',
        sha: 'def456',
        event: { workflow_run: { head_sha: 'abc123' } },
      },
      inputs: { revision: 'abc123' },
      steps: { guard: { outputs: { verdict: 'hold' } } },
    }),
  ).toBe(rendered);
});

test.each([
  [`\${{ secrets.TOKEN }}`, 'unsupported expression: secrets.TOKEN'],
  [
    `\${{ inputs.revision || github.sha }}`,
    'unsupported expression: inputs.revision || github.sha',
  ],
  [`\${{ github.event }}`, 'github.event is not a primitive'],
])('it rejects %p', (value, message) => {
  expect(() =>
    renderActionsTemplate(value, {
      github: { event: { workflow_run: {} } },
      inputs: {},
      steps: {},
    }),
  ).toThrowWithMessage(Error, message);
});

test('it rejects a value that is neither text, a number nor a boolean', () => {
  expect(() =>
    renderActionsTemplate(['a'], { github: {}, inputs: {}, steps: {} }),
  ).toThrowWithMessage(TypeError, 'unsupported workflow value: ["a"]');
});
