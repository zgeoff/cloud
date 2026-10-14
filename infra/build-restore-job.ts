// a backup Job's container: the parts a restore overrides, and the rest it keeps
interface BackupContainer {
  readonly name: string;
  readonly args: readonly string[];
  readonly env: readonly { readonly name: string; readonly value: string }[];
  readonly resources?: unknown;
  readonly [field: string]: unknown;
}

interface BackupPodSpec {
  readonly restartPolicy: string;
  readonly containers: readonly BackupContainer[];
  readonly [field: string]: unknown;
}

interface RestoreJobInputs {
  // the workload's name, which names the Job (<name>-restore-<suffix>)
  readonly name: string;
  readonly namespace: string;

  // the backup CronJob's pod, from its builder
  readonly backupPod: BackupPodSpec;
}

// A one-off restore Job from a runbook: the backup pod, run once, with its container's `restore` of
// SNAPSHOT=latest and without the backup's resources, so a large restore escapes the nightly
// limit. The image, the user, the claim and the Secret stay the backup's.
export function buildRestoreJob(inputs: RestoreJobInputs) {
  const pod: BackupPodSpec = {
    ...inputs.backupPod,
    restartPolicy: 'Never',
    containers: inputs.backupPod.containers.map((container) => buildRestoreContainer(container)),
  };

  return {
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: { generateName: `${inputs.name}-restore-`, namespace: inputs.namespace },
    spec: {
      backoffLimit: 0,
      ttlSecondsAfterFinished: 86_400,
      template: { spec: pod },
    },
  };
}

function buildRestoreContainer(container: BackupContainer): BackupContainer {
  const { resources: _resources, ...rest } = container;

  return {
    ...rest,
    name: 'restore',
    args: ['restore'],
    env: [...container.env, { name: 'SNAPSHOT', value: 'latest' }],
  };
}
