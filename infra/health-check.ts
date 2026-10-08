import {
  R2Bucket,
  WorkersCronTrigger,
  WorkersScript,
  WorkersScriptSubdomain,
} from '@pulumi/cloudflare';
import { buildHealthCheckBindings } from './build-health-check-bindings.ts';
import { buildWorkerBundle } from './build-worker-bundle.ts';

interface HealthCheckInputs {
  readonly accountID: string;
  readonly targets: readonly { readonly name: string; readonly url: string }[];
  readonly alertURL: string | undefined;
}

const scriptName = 'geoff-cloud-health-check';

// The API's full defaults: a bare { enabled: true } reads back expanded and shows as
// drift on every preview.
const observability = {
  enabled: true,
  headSamplingRate: 1,
  logs: { enabled: true, headSamplingRate: 1, invocationLogs: true, persist: true },
  traces: { enabled: false, headSamplingRate: 1, persist: true },
};

// The external health check (#8): a Worker on a 5-minute cron, bundled from
// workers/health-check by Bun at deploy time. Its state lives in an R2 bucket.
export async function createHealthCheck(inputs: HealthCheckInputs): Promise<WorkersCronTrigger> {
  const content = await buildWorkerBundle(
    new URL('../workers/health-check/index.ts', import.meta.url).pathname,
  );

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
    observability,
    bindings: buildHealthCheckBindings({
      stateBucket: state.name,
      targets: inputs.targets,
      alertURL: inputs.alertURL,
    }),
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
