import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { nixieSandboxImagesPayloadSchema } from '@zgeoff/cloud-topology';
import type { NixieSandboxImagesPayload } from '@zgeoff/cloud-topology';
import { z } from 'zod';
import { readSandboxImageScript } from './read-sandbox-image-script.ts';
import { runProcess } from './run-process.ts';
import type { Runner } from './run-process.ts';

export interface SandboxImageJobOptions {
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly kubeconfig: string;
  readonly run: Runner;
  readonly readScript: () => Promise<string>;
  readonly tempRoot: string;
  readonly now: () => number;
  readonly sleep: (delayMs: number) => Promise<void>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

// the Job's own deadline is 900 s, after which Kubernetes marks it failed; the wait outlasts it
const waitMs = 960_000;
const pollMs = 5000;

// the API server can refuse one read in a rollout of its own; this many in a row end the wait
const failedReadLimit = 3;

export async function runSandboxImageJob(
  options: Readonly<SandboxImageJobOptions>,
): Promise<number> {
  const payload = parsePayload(options.env['NIXIE_SANDBOX_IMAGES']);

  if (!payload.ok) {
    options.printErr(`run-sandbox-image-job: ${payload.error}\n`);

    return 2;
  }

  if (options.kubeconfig.trim() === '') {
    options.printErr('run-sandbox-image-job: the kubeconfig comes on stdin, which is empty\n');

    return 2;
  }

  const directory = await mkdtemp(join(options.tempRoot, 'nixie-sandbox-images-'));

  try {
    const kubeconfigPath = join(directory, 'kubeconfig');

    await writeFile(kubeconfigPath, options.kubeconfig, { mode: 0o600 });

    const kubectl = (args: readonly string[], stdin?: string) =>
      options.run(['kubectl', ...args], {
        env: { ...options.env, KUBECONFIG: kubeconfigPath },
        ...(stdin === undefined ? {} : { stdin: Buffer.from(stdin) }),
      });

    return await runJob(options, payload.value, kubectl);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function parsePayload(
  text: string | undefined,
):
  | { readonly ok: true; readonly value: NixieSandboxImagesPayload }
  | { readonly ok: false; readonly error: string } {
  if (text === undefined) {
    return { ok: false, error: 'NIXIE_SANDBOX_IMAGES must hold the payload that infra builds' };
  }

  const result = nixieSandboxImagesPayloadSchema.safeParse(parseJSON(text));

  return result.success
    ? { ok: true, value: result.data }
    : { ok: false, error: `NIXIE_SANDBOX_IMAGES: ${z.prettifyError(result.error)}` };
}

function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

type Kubectl = (
  args: readonly string[],
  stdin?: string,
) => Promise<{ readonly exitCode: number; readonly stdout: Buffer; readonly stderr: Buffer }>;

async function runJob(
  options: Readonly<SandboxImageJobOptions>,
  payload: NixieSandboxImagesPayload,
  kubectl: Kubectl,
): Promise<number> {
  const namespaceArgs = ['--namespace', payload.namespace];

  const configMap = {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: { name: payload.configMap, namespace: payload.namespace },
    data: { [payload.scriptKey]: await options.readScript() },
  };

  // a run that stopped early leaves its ConfigMap, and create refuses a name that exists
  const steps: readonly (readonly [string, readonly string[], string | undefined])[] = [
    [
      'remove the last ConfigMap',
      ['delete', 'configmap', payload.configMap, ...namespaceArgs, '--ignore-not-found'],
      undefined,
    ],
    ['create the ConfigMap', ['create', '--filename', '-'], JSON.stringify(configMap)],
  ];

  for (const [what, args, stdin] of steps) {
    const result = await kubectl(args, stdin);

    if (result.exitCode !== 0) {
      options.printErr(
        `run-sandbox-image-job: kubectl could not ${what} (exit ${result.exitCode}): ${result.stderr.toString()}`,
      );

      return 1;
    }
  }

  const exitCode = await runCreatedJob(options, payload, kubectl);

  const removed = await kubectl([
    'delete',
    'configmap',
    payload.configMap,
    ...namespaceArgs,
    '--ignore-not-found',
  ]);

  // the next run removes a ConfigMap that this one leaves, so a failed removal changes no outcome
  if (removed.exitCode !== 0) {
    options.printErr(
      `run-sandbox-image-job: kubectl could not remove the ConfigMap ${payload.configMap} (exit ${removed.exitCode}), so the next run removes it: ${removed.stderr.toString()}`,
    );
  }

  return exitCode;
}

async function runCreatedJob(
  options: Readonly<SandboxImageJobOptions>,
  payload: NixieSandboxImagesPayload,
  kubectl: Kubectl,
): Promise<number> {
  const namespaceArgs = ['--namespace', payload.namespace];

  const created = await kubectl(['create', '--filename', '-', '--output', 'name'], payload.job);

  const name = created.stdout.toString().trim();

  if (created.exitCode !== 0 || name === '') {
    options.printErr(
      `run-sandbox-image-job: kubectl could not create the Job (exit ${created.exitCode}): ${created.stderr.toString()}`,
    );

    return 1;
  }

  options.printOut(`run-sandbox-image-job: started ${name}\n`);

  const outcome = await waitForJob(options, (args) => kubectl([...args, name, ...namespaceArgs]));
  const logs = await kubectl(['logs', name, ...namespaceArgs]);

  const logText = logs.exitCode === 0 ? logs.stdout.toString() : logs.stderr.toString();

  if (outcome.isComplete) {
    options.printOut(logText);
    options.printOut(`run-sandbox-image-job: ${name} added nixie's sandbox images\n`);

    return 0;
  }

  options.printErr(logText);

  options.printErr(
    `run-sandbox-image-job: ${name} ${outcome.text}, so nixie's sandbox images are not all in impd and nixie does not roll\n`,
  );

  return 1;
}

interface JobOutcome {
  readonly isComplete: boolean;
  readonly text: string;
}

async function waitForJob(
  options: Readonly<SandboxImageJobOptions>,
  readJob: (args: readonly string[]) => ReturnType<Kubectl>,
): Promise<JobOutcome> {
  const deadline = options.now() + waitMs;
  let failedReads = 0;

  while (options.now() < deadline) {
    const result = await readJob(['get', '--output', 'json']);

    if (result.exitCode === 0) {
      failedReads = 0;

      const outcome = findJobOutcome(result.stdout.toString());

      if (outcome !== undefined) {
        return outcome;
      }
    } else {
      const failure = `could not be read (exit ${String(result.exitCode)}): ${result.stderr.toString().trim()}`;

      failedReads += 1;

      options.printErr(`run-sandbox-image-job: the Job ${failure}\n`);

      if (failedReads === failedReadLimit) {
        return { isComplete: false, text: failure };
      }
    }

    await options.sleep(pollMs);
  }

  return { isComplete: false, text: `did not finish in ${String(waitMs / 1000)} s` };
}

const conditionSchema = z.looseObject({
  type: z.string(),
  status: z.string(),
  reason: z.string().optional(),
});

const jobStatusSchema = z.looseObject({
  status: z.looseObject({ conditions: z.array(conditionSchema).optional() }).optional(),
});

function findJobOutcome(text: string): JobOutcome | undefined {
  const result = jobStatusSchema.safeParse(parseJSON(text));
  const conditions = result.success ? (result.data.status?.conditions ?? []) : [];

  const finished = conditions.find(
    (condition) => condition.status === 'True' && ['Complete', 'Failed'].includes(condition.type),
  );

  if (finished === undefined) {
    return undefined;
  }

  return finished.type === 'Complete'
    ? { isComplete: true, text: 'completed' }
    : { isComplete: false, text: `failed (${finished.reason ?? 'no reason'})` };
}

if (import.meta.main) {
  process.exitCode = await runSandboxImageJob({
    env: process.env,
    kubeconfig: await Bun.stdin.text(),
    run: runProcess,
    readScript: readSandboxImageScript,
    tempRoot: tmpdir(),
    now: Date.now,
    sleep: Bun.sleep,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
