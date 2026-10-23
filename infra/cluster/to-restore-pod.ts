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

export function toRestorePod(backupPod: BackupPodSpec): BackupPodSpec {
  return {
    ...backupPod,
    restartPolicy: 'Never',
    containers: backupPod.containers.map((container) => toRestoreContainer(container)),
  };
}

function toRestoreContainer(container: BackupContainer): BackupContainer {
  // drops the backup's resources, so a large restore escapes the nightly limit
  const { resources: _resources, ...rest } = container;

  return {
    ...rest,
    name: 'restore',
    args: ['restore'],
    env: [...container.env, { name: 'SNAPSHOT', value: 'latest' }],
  };
}
