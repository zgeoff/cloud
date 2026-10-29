import type { input } from '@pulumi/kubernetes/types';
import { topology } from '@zgeoff/cloud-topology';
import { podLabels } from '../shared/pod-labels.ts';
import { nixieAgeKeyKey, nixieSecretsFileKey } from './build-nixie-spec.ts';

export interface NixieSandboxImagesJobInputs {
  readonly image: string;
  readonly secret: string;
}

export type NixieSandboxImagesJob = input.batch.v1.Job & {
  readonly metadata: input.meta.v1.ObjectMeta;
};

export const nixieSandboxImagesConfigMap = 'nixie-sandbox-images';
export const nixieSandboxImagesScriptKey = 'add-sandbox-images.js';
const scriptDirectory = '/opt/nixie-sandbox-images';

// Kubernetes refuses a change to a Job's pod template, so a Job that Pulumi owned would be replaced
// at each nixie release, and the prod deploy's guard holds every replace
export function buildNixieSandboxImagesJob(
  inputs: NixieSandboxImagesJobInputs,
): NixieSandboxImagesJob {
  return {
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: {
      generateName: 'nixie-sandbox-images-',
      namespace: 'nixie',
      labels: podLabels.nixieSandboxImages,
    },
    spec: {
      backoffLimit: 0,
      activeDeadlineSeconds: 900,
      ttlSecondsAfterFinished: 86_400,
      template: {
        metadata: { labels: podLabels.nixieSandboxImages },
        spec: {
          restartPolicy: 'Never',
          automountServiceAccountToken: false,
          enableServiceLinks: false,
          securityContext: {
            fsGroup: 10_001,
            runAsNonRoot: true,
            seccompProfile: { type: 'RuntimeDefault' },
          },
          volumes: [
            {
              name: 'secrets',
              secret: {
                secretName: inputs.secret,
                defaultMode: 0o440,
                items: [
                  { key: nixieSecretsFileKey, path: nixieSecretsFileKey },
                  { key: nixieAgeKeyKey, path: nixieAgeKeyKey },
                ],
              },
            },
            {
              name: 'script',
              configMap: {
                name: nixieSandboxImagesConfigMap,
                items: [{ key: nixieSandboxImagesScriptKey, path: nixieSandboxImagesScriptKey }],
              },
            },
            { name: 'tmp', emptyDir: {} },
          ],
          containers: [
            {
              name: 'add',
              image: inputs.image,
              command: ['bun', `${scriptDirectory}/${nixieSandboxImagesScriptKey}`],
              env: [
                { name: 'IMPD_URL', value: `https://${topology.imp.domain}` },
                { name: 'NIXIE_SECRETS_FILE', value: `/etc/nixie/secrets/${nixieSecretsFileKey}` },
                { name: 'SOPS_AGE_KEY_FILE', value: `/etc/nixie/secrets/${nixieAgeKeyKey}` },

                // the image's user has no home directory
                { name: 'HOME', value: '/tmp' },
              ],
              volumeMounts: [
                { name: 'secrets', mountPath: '/etc/nixie/secrets', readOnly: true },
                { name: 'script', mountPath: scriptDirectory, readOnly: true },
                { name: 'tmp', mountPath: '/tmp' },
              ],
              securityContext: {
                allowPrivilegeEscalation: false,
                readOnlyRootFilesystem: true,
                capabilities: { drop: ['ALL'] },
                runAsUser: 10_001,
                runAsGroup: 10_001,
              },
              resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '512Mi' } },
            },
          ],
        },
      },
    },
  };
}
