import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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

export async function runSandboxImageJob(
  options: Readonly<SandboxImageJobOptions>,
): Promise<number> {
  const job = parseJob(options.env['NIXIE_SANDBOX_IMAGES_JOB']);

  if (!job.ok) {
    options.printErr(`run-sandbox-image-job: ${job.error}\n`);

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

    return await runJob(options, job.value, kubectl);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

interface ParsedJob {
  readonly manifest: string;
  readonly namespace: string;
  readonly configMap: string;
  readonly scriptKey: string;
}

const scriptItemSchema = z.looseObject({ key: z.string() });

const configMapSourceSchema = z.looseObject({
  name: z.string(),
  items: z.tuple([scriptItemSchema]),
});

const volumeSchema = z.looseObject({
  name: z.string(),
  configMap: configMapSourceSchema.optional(),
});

const podSpecSchema = z.looseObject({ volumes: z.array(volumeSchema) });

const jobSchema = z.looseObject({
  metadata: z.looseObject({ namespace: z.string() }),
  spec: z.looseObject({ template: z.looseObject({ spec: podSpecSchema }) }),
});

function parseJob(
  text: string | undefined,
):
  | { readonly ok: true; readonly value: ParsedJob }
  | { readonly ok: false; readonly error: string } {
  if (text === undefined) {
    return { ok: false, error: 'NIXIE_SANDBOX_IMAGES_JOB must hold the Job to run' };
  }

  const result = jobSchema.safeParse(parseJSON(text));

  if (!result.success) {
    return { ok: false, error: `NIXIE_SANDBOX_IMAGES_JOB: ${z.prettifyError(result.error)}` };
  }

  const script = result.data.spec.template.spec.volumes.find((volume) => volume.name === 'script');

  if (script?.configMap === undefined) {
    return { ok: false, error: 'NIXIE_SANDBOX_IMAGES_JOB has no ConfigMap volume named script' };
  }

  return {
    ok: true,
    value: {
      manifest: text,
      namespace: result.data.metadata.namespace,
      configMap: script.configMap.name,
      scriptKey: script.configMap.items[0].key,
    },
  };
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
  job: ParsedJob,
  kubectl: Kubectl,
): Promise<number> {
  const namespaceArgs = ['--namespace', job.namespace];

  const configMap = {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: { name: job.configMap, namespace: job.namespace },
    data: { [job.scriptKey]: await options.readScript() },
  };

  // a run that stopped early leaves its ConfigMap, and create refuses a name that exists
  const steps: readonly (readonly [string, readonly string[], string | undefined])[] = [
    [
      'remove the last ConfigMap',
      ['delete', 'configmap', job.configMap, ...namespaceArgs, '--ignore-not-found'],
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

  try {
    return await runCreatedJob(options, job, kubectl);
  } finally {
    await kubectl(['delete', 'configmap', job.configMap, ...namespaceArgs, '--ignore-not-found']);
  }
}

async function runCreatedJob(
  options: Readonly<SandboxImageJobOptions>,
  job: ParsedJob,
  kubectl: Kubectl,
): Promise<number> {
  const namespaceArgs = ['--namespace', job.namespace];

  const created = await kubectl(['create', '--filename', '-', '--output', 'name'], job.manifest);

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

  while (options.now() < deadline) {
    const result = await readJob(['get', '--output', 'json']);

    const outcome = result.exitCode === 0 ? findJobOutcome(result.stdout.toString()) : undefined;

    if (outcome !== undefined) {
      return outcome;
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
