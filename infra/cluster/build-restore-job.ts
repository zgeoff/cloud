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
  readonly name: string;
  readonly namespace: string;
  readonly backupPod: BackupPodSpec;
}

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
  // drops the backup's resources, so a large restore escapes the nightly limit
  const { resources: _resources, ...rest } = container;

  return {
    ...rest,
    name: 'restore',
    args: ['restore'],
    env: [...container.env, { name: 'SNAPSHOT', value: 'latest' }],
  };
}
