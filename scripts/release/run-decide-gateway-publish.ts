import { appendFile } from 'node:fs/promises';
import type { Runner } from '../run-process.ts';
import { runProcess } from '../run-process.ts';
import type { GatewayPublishInput } from './decide-gateway-publish.ts';
import { decideGatewayPublish } from './decide-gateway-publish.ts';
import { runChecked } from './run-checked.ts';

export interface RunDecideGatewayPublishOptions {
  readonly env: Readonly<Record<string, string | undefined>>;

  // the checkout of the commit the workflow runs on
  readonly cwd: string;
  readonly run: Runner;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

// The atc-gateway images workflow's decide step: for a push, it lists the files that the push
// changed between BEFORE and SHA, decides, and writes publish=true or publish=false to
// GITHUB_OUTPUT. It prints the decision, and copies it to GITHUB_STEP_SUMMARY.
export async function runDecideGatewayPublish(
  options: Readonly<RunDecideGatewayPublishOptions>,
): Promise<number> {
  const env = options.env;
  const output = env['GITHUB_OUTPUT'] ?? '';
  const summary = env['GITHUB_STEP_SUMMARY'] ?? '';

  const missing = ['EVENT', 'REF', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY'].find(
    (name) => (env[name] ?? '') === '',
  );

  if (missing !== undefined) {
    options.printErr(`${missing} must be set, as the workflow sets it\n`);

    return 2;
  }

  const input = await readInput(options);

  if (input instanceof Error) {
    options.printErr(`${input.message}\n`);

    return 1;
  }

  const decision = decideGatewayPublish(input);
  const text = `${decision.action}: ${decision.reason}\n`;

  await appendFile(output, `publish=${String(decision.action === 'publish')}\n`);
  await appendFile(summary, text);

  options.printOut(text);

  return 0;
}

async function readInput(
  options: Readonly<RunDecideGatewayPublishOptions>,
): Promise<GatewayPublishInput | Error> {
  const env = options.env;
  const eventName = env['EVENT'] ?? '';
  const changedFiles = eventName === 'push' ? await readChangedFiles(options) : [];

  return changedFiles instanceof Error
    ? changedFiles
    : { eventName, ref: env['REF'] ?? '', pushInput: env['PUSH_INPUT'] ?? '', changedFiles };
}

// the shallow checkout lacks the commit before the push, so it fetches that commit first
async function readChangedFiles(options: Readonly<RunDecideGatewayPublishOptions>) {
  const before = options.env['BEFORE'] ?? '';
  const sha = options.env['SHA'] ?? '';

  if (!/^[0-9a-f]{40}$/u.test(before) || /^0+$/u.test(before) || !/^[0-9a-f]{40}$/u.test(sha)) {
    return new Error(`a push needs BEFORE and SHA as full commits, not '${before}' and '${sha}'`);
  }

  const runOptions = { cwd: options.cwd, env: options.env };

  const fetched = await runChecked(
    options.run,
    ['git', 'fetch', '-q', '--depth=1', 'origin', before],
    runOptions,
  );

  const listed =
    fetched instanceof Error
      ? fetched
      : await runChecked(options.run, ['git', 'diff', '--name-only', before, sha], runOptions);

  return listed instanceof Error ? listed : listed.split('\n').filter((file) => file !== '');
}

if (import.meta.main) {
  process.exitCode = await runDecideGatewayPublish({
    env: process.env,
    cwd: process.cwd(),
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
