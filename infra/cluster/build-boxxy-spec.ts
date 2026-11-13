import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { buildCloudflaredSidecar, tunnelTokenVolume } from './build-cloudflared-sidecar.ts';
import {
  boxxyOwnerPort,
  boxxyTrustedIssuersFolder,
  boxxyWorkerPort,
} from './render-boxxy-config.ts';

export const boxxyLabels = { app: 'boxxy-server' };

// the image's nonroot user, which owns the volume through fsGroup
const nonrootID = 65_532;

export interface BoxxySpecInputs {
  // the boxxy image, by tag and digest
  readonly image: string;

  readonly serviceName: Output<string>;

  // the ConfigMap that holds the configuration file
  readonly configMap: Output<string>;

  // the ConfigMap of the trust documents and the file name of each; with none, the pod mounts no
  // issuers folder
  readonly trustDocuments?: {
    readonly configMap: Output<string>;
    readonly files: readonly string[];
  };

  // the Secret with the worker token and the atc token, and each optional token the config needs
  readonly tokenSecret: Output<string>;
  readonly pepysSigningSecret: boolean;
  readonly githubToken: boolean;
  readonly reviewApp: boolean;
  readonly notice: boolean;
  readonly pullSecret: string;

  // the Secret with the token of the public door's tunnel; with it, the pod runs the tunnel's
  // connector beside the server
  readonly doorTunnelToken?: Output<string>;
}

export function buildBoxxySpec(inputs: BoxxySpecInputs): input.apps.v1.StatefulSetSpec {
  return {
    // SQLite takes one writer
    replicas: 1,

    // a StatefulSet's rolling update stops boxxy-0 before it starts the new one, so two pods never
    // hold the store at once; Parallel lets an apply replace an unready boxxy-0
    updateStrategy: { type: 'RollingUpdate' },
    podManagementPolicy: 'Parallel',
    serviceName: inputs.serviceName,
    selector: { matchLabels: boxxyLabels },
    template: {
      metadata: { labels: boxxyLabels },
      spec: {
        securityContext: {
          fsGroup: nonrootID,
          runAsNonRoot: true,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        automountServiceAccountToken: false,
        enableServiceLinks: false,
        imagePullSecrets: [{ name: inputs.pullSecret }],
        volumes: [
          { name: 'config', configMap: { name: inputs.configMap } },

          // SQLite writes a statement journal's temp file to /tmp, and the root is read-only; the
          // pages count against the container's memory limit
          { name: 'tmp', emptyDir: { medium: 'Memory', sizeLimit: '16Mi' } },
          ...(inputs.trustDocuments === undefined
            ? []
            : [{ name: 'issuers', configMap: { name: inputs.trustDocuments.configMap } }]),

          // group-readable, so the connector reads it through fsGroup
          ...(inputs.doorTunnelToken === undefined
            ? []
            : [
                {
                  name: tunnelTokenVolume,
                  secret: { secretName: inputs.doorTunnelToken, defaultMode: 0o440 },
                },
              ]),
        ],
        containers: [
          buildBoxxyContainer(inputs),
          ...(inputs.doorTunnelToken === undefined ? [] : [buildCloudflaredSidecar()]),
        ],
      },
    },
    volumeClaimTemplates: [
      {
        metadata: { name: 'data' },
        spec: {
          accessModes: ['ReadWriteOnce'],

          // keeps the volume when the claim is deleted
          storageClassName: 'local-path-retain',
          resources: { requests: { storage: '1Gi' } },
        },
      },
    ],
  };
}

export const workerTokenKey = 'worker-token';
export const atcTokenKey = 'atc-token';
export const pepysSigningSecretKey = 'pepys-signing-secret';
export const githubTokenKey = 'github-token';
export const noticeSessionKey = 'atc-notice-session';
export const noticeTokenKey = 'atc-notice-token';

// the noslop App's keys, by the variable the server reads each one from
export const reviewAppKeys = {
  NOSLOP_GITHUB_APP_ID: 'noslop-app-id',
  NOSLOP_GITHUB_APP_PRIVATE_KEY: 'noslop-app-private-key',
  NOSLOP_GITHUB_APP_INSTALLATION_ID: 'noslop-app-installation-id',
} as const;

// the image reads its configuration file here (images/boxxy/Dockerfile)
const configFolder = '/etc/boxxy';

export const configFileName = 'config.json';

function buildBoxxyContainer(inputs: BoxxySpecInputs): input.core.v1.Container {
  return {
    name: 'boxxy',
    image: inputs.image,
    ports: [
      { name: 'owner', containerPort: boxxyOwnerPort },
      { name: 'worker', containerPort: boxxyWorkerPort },
    ],
    env: [
      { name: 'BOXXY_CONFIG', value: `${configFolder}/${configFileName}` },
      {
        name: 'BOXXY_WORKER_TOKEN',
        valueFrom: {
          secretKeyRef: { name: inputs.tokenSecret, key: workerTokenKey },
        },
      },
      {
        name: 'BOXXY_ATC_TOKEN',
        valueFrom: {
          secretKeyRef: { name: inputs.tokenSecret, key: atcTokenKey },
        },
      },
      ...(inputs.pepysSigningSecret
        ? [
            {
              name: 'BOXXY_PEPYS_SIGNING_SECRET',
              valueFrom: {
                secretKeyRef: { name: inputs.tokenSecret, key: pepysSigningSecretKey },
              },
            },
          ]
        : []),
      ...(inputs.githubToken
        ? [
            {
              name: 'BOXXY_GITHUB_TOKEN',
              valueFrom: { secretKeyRef: { name: inputs.tokenSecret, key: githubTokenKey } },
            },
          ]
        : []),
      ...(inputs.notice
        ? [
            {
              name: 'BOXXY_ATC_NOTICE_SESSION',
              valueFrom: { secretKeyRef: { name: inputs.tokenSecret, key: noticeSessionKey } },
            },
            {
              name: 'BOXXY_ATC_NOTICE_TOKEN',
              valueFrom: { secretKeyRef: { name: inputs.tokenSecret, key: noticeTokenKey } },
            },
          ]
        : []),
      ...(inputs.reviewApp
        ? Object.entries(reviewAppKeys).map(([name, key]) => ({
            name,
            valueFrom: { secretKeyRef: { name: inputs.tokenSecret, key } },
          }))
        : []),
    ],

    // /healthz is on the owner listener only
    readinessProbe: {
      httpGet: { path: '/healthz', port: boxxyOwnerPort },
      periodSeconds: 10,
      failureThreshold: 3,
    },
    livenessProbe: {
      httpGet: { path: '/healthz', port: boxxyOwnerPort },
      periodSeconds: 30,
      failureThreshold: 3,
    },
    volumeMounts: [
      { name: 'data', mountPath: '/data' },
      { name: 'config', mountPath: configFolder, readOnly: true },
      { name: 'tmp', mountPath: '/tmp' },

      // one subPath mount per document, so the folder holds regular files: a ConfigMap volume
      // shows each key as a symlink, which a server before 0.1.5 skips
      ...(inputs.trustDocuments?.files ?? []).map((file) => ({
        name: 'issuers',
        mountPath: `${boxxyTrustedIssuersFolder}/${file}`,
        subPath: file,
        readOnly: true,
      })),
    ],
    securityContext: {
      allowPrivilegeEscalation: false,
      readOnlyRootFilesystem: true,
      capabilities: { drop: ['ALL'] },
      runAsUser: nonrootID,
      runAsGroup: nonrootID,
    },

    // an estimate with no measured figure yet; read the peak of a week of
    // container_memory_working_set_bytes and tighten it
    resources: {
      requests: { cpu: '50m', memory: '128Mi' },
      limits: { memory: '256Mi' },
    },
  };
}
