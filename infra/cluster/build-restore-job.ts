interface RestoreJobInputs {
  readonly name: string;
  readonly namespace: string;
  readonly pod: unknown;
}

export function buildRestoreJob(inputs: RestoreJobInputs) {
  return {
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: { generateName: `${inputs.name}-restore-`, namespace: inputs.namespace },
    spec: {
      backoffLimit: 0,
      ttlSecondsAfterFinished: 86_400,
      template: { spec: inputs.pod },
    },
  };
}
