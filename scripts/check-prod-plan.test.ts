import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkProdPlan } from './check-prod-plan.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'check-prod-plan-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { directory, printOut, printErr };
}

test('it allows the apply of a plan that only updates a workload, after a clean drift check', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'plan.json'),
    JSON.stringify({
      steps: [
        { op: 'same', urn: 'urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod' },
        {
          op: 'update',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:apps/v1:StatefulSet::nixie',
          diffReasons: ['spec'],
        },
      ],
      changeSummary: { same: 1, update: 1 },
    }),
  );

  const exitCode = await checkProdPlan({
    args: [join(ctx.directory, 'plan.json'), 'success'],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['apply: the plan holds no delete, replace or guarded change\n'],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it holds a plan with a replace and names the step', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'plan.json'),
    JSON.stringify({
      steps: [
        { op: 'same', urn: 'urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod' },
        {
          op: 'replace',
          urn: 'urn:pulumi:prod::geoff-cloud::tailscale:index/tailnetKey:TailnetKey::imp',
          replaceReasons: ['expiry'],
        },
      ],
      changeSummary: { same: 1, replace: 1 },
    }),
  );

  const exitCode = await checkProdPlan({
    args: [join(ctx.directory, 'plan.json'), 'success'],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(3);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    [
      "hold: \n- replace urn:pulumi:prod::geoff-cloud::tailscale:index/tailnetKey:TailnetKey::imp\n- the plan's summary counts 1 replace\n",
    ],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it holds a plan that only moves a CNAME to another tunnel', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'plan.json'),
    JSON.stringify({
      steps: [
        { op: 'same', urn: 'urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod' },
        {
          op: 'update',
          urn: 'urn:pulumi:prod::geoff-cloud::cloudflare:index/dnsRecord:DnsRecord::atc',
          diffReasons: ['content'],
        },
      ],
      changeSummary: { same: 1, update: 1 },
    }),
  );

  const exitCode = await checkProdPlan({
    args: [join(ctx.directory, 'plan.json'), 'success'],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(3);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    [
      'hold: \n- update of a guarded resource urn:pulumi:prod::geoff-cloud::cloudflare:index/dnsRecord:DnsRecord::atc\n',
    ],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it holds a clean plan after a failed drift check', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'plan.json'),
    JSON.stringify({
      steps: [
        { op: 'same', urn: 'urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod' },
      ],
    }),
  );

  const exitCode = await checkProdPlan({
    args: [join(ctx.directory, 'plan.json'), 'failure'],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(3);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['hold: \n- the drift check from the deployed revision failed\n'],
  ]);
});

test('it fails on a preview that reported an error, and prints the error', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'plan.json'),
    JSON.stringify({
      steps: [
        { op: 'same', urn: 'urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod' },
      ],
      diagnostics: [
        { message: 'Previewing update (prod)', severity: 'info' },
        {
          urn: 'urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod',
          message: 'Error: the cluster mode is unset\n',
          severity: 'error',
        },
      ],
    }),
  );

  const exitCode = await checkProdPlan({
    args: [join(ctx.directory, 'plan.json'), 'success'],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['preview error: Error: the cluster mode is unset\n'],
  ]);

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it fails on a digest that is not JSON', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'plan.json'), 'error: failed to load the stack\n');

  const exitCode = await checkProdPlan({
    args: [join(ctx.directory, 'plan.json'), 'success'],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [`check-prod-plan: ${join(ctx.directory, 'plan.json')} holds no preview digest\n`],
  ]);
});

test('it fails on a digest file that does not exist', async () => {
  const ctx = await setupTest();

  const exitCode = await checkProdPlan({
    args: [join(ctx.directory, 'missing.json'), 'success'],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [`check-prod-plan: ${join(ctx.directory, 'missing.json')} holds no preview digest\n`],
  ]);
});

test.each([
  ['no arguments', []],
  ['a drift outcome it does not know', ['plan.json', 'skipped']],
  ['an extra argument', ['plan.json', 'success', 'extra']],
])('it rejects %s with its usage', async (_label: string, args: readonly string[]) => {
  const ctx = await setupTest();

  const exitCode = await checkProdPlan({
    args,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['usage: check-prod-plan.ts <preview digest> <drift outcome: success|failure>\n'],
  ]);
});
