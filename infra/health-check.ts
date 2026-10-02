import {
  R2Bucket,
  WorkersCronTrigger,
  WorkersScript,
  WorkersScriptSubdomain,
} from '@pulumi/cloudflare';
import { secret } from '@pulumi/pulumi';

interface HealthCheckInputs {
  readonly accountID: string;
  readonly targets: readonly { readonly name: string; readonly url: string }[];
  readonly alertURL: string | undefined;
}

const scriptName = 'geoff-cloud-health-check';

// The external health check (#8): a Worker on a 5-minute cron, bundled from
// workers/health-check by Bun at deploy time. Its state lives in an R2 bucket.
export async function createHealthCheck(inputs: HealthCheckInputs): Promise<WorkersCronTrigger> {
  const content = await buildWorkerBundle();

  // R2, not KV: the API token has R2 rights and no KV rights
  const state = new R2Bucket('health-check-state', {
    accountId: inputs.accountID,
    name: `${scriptName}-state`,
    location: 'oc',
  });

  const worker = new WorkersScript('health-check', {
    accountId: inputs.accountID,
    scriptName,
    content,
    mainModule: 'index.js',
    compatibilityDate: '2026-09-01',
    observability: { enabled: true },
    bindings: [
      { name: 'STATE', type: 'r2_bucket', bucketName: state.name },
      { name: 'TARGETS', type: 'plain_text', text: JSON.stringify(inputs.targets) },
      ...(inputs.alertURL === undefined || inputs.alertURL === ''
        ? []
        : [{ name: 'ALERT_URL', type: 'secret_text', text: secret(inputs.alertURL) }]),
    ],
  });

  // cron only: no public workers.dev URL for this script
  const route = new WorkersScriptSubdomain('health-check', {
    accountId: inputs.accountID,
    scriptName: worker.scriptName,
    enabled: false,
    previewsEnabled: false,
  });

  return new WorkersCronTrigger(
    'health-check',
    {
      accountId: inputs.accountID,
      scriptName: worker.scriptName,
      schedules: [{ cron: '*/5 * * * *' }],
    },
    { dependsOn: [route] },
  );
}

async function buildWorkerBundle(): Promise<string> {
  const result = await Bun.build({
    entrypoints: [new URL('../workers/health-check/index.ts', import.meta.url).pathname],
    format: 'esm',
    target: 'browser',
    minify: false,
  });

  const [output] = result.outputs;

  if (!result.success || output === undefined) {
    throw new Error(
      `health-check bundle failed: ${result.logs.map((log) => log.message).join('\n')}`,
    );
  }

  return output.text();
}
