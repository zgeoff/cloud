import type { input } from '@pulumi/kubernetes/types';
import type { NixieBackupPodInputs } from './build-nixie-backup-pod-spec.ts';
import { buildNixieBackupPodSpec } from './build-nixie-backup-pod-spec.ts';

// A failed restic step leaves a failed receipt and exits 1, and a rerun skips each set that holds a
// receipt and exits 0, so any retry would turn the failed run into a successful Job.
export function buildNixieBackupCronJobSpec(
  inputs: NixieBackupPodInputs,
): input.batch.v1.CronJobSpec {
  return {
    // half an hour after the atc gateway's backup, so the two never share the node's disk
    schedule: '0 4 * * *',
    timeZone: 'Australia/Melbourne',
    suspend: false,
    concurrencyPolicy: 'Forbid',
    jobTemplate: {
      spec: {
        backoffLimit: 0,
        template: { spec: buildNixieBackupPodSpec(inputs) },
      },
    },
  };
}
