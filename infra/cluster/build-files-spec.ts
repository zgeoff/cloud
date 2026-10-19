import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';

// the files service's port in the pod, and its pod labels
export const filesPort = 8080;
export const filesLabels = { app: 'files' };

// the keys of the Secret that holds each role token's SHA-256
export const agentTokenHashKey = 'agent-token-sha256';
export const ownerTokenHashKey = 'owner-token-sha256';

// the image's nonroot user, which owns the volume through fsGroup
const nonrootID = 65_532;

export interface FilesSpecInputs {
  // the files image, by tag and digest
  readonly image: string;

  // the public origin of the file URLs, such as https://files.geoff.cloud
  readonly publicURL: string;

  // the Service that governs the StatefulSet
  readonly serviceName: Output<string>;

  // the Secret with the token hashes, and the dockerconfigjson Secret that pulls the image
  readonly tokenSecret: Output<string>;
  readonly pullSecret: string;
}

// The files service's StatefulSet spec: one replica, because SQLite takes one writer, on a 20 GiB
// ReadWriteOnce volume that outlives its claim and holds the files and the metadata file. The pod
// reads only the token hashes, and runs as the image's nonroot user on a read-only root.
export function buildFilesSpec(inputs: FilesSpecInputs): input.apps.v1.StatefulSetSpec {
  return {
    replicas: 1,

    // a StatefulSet's rolling update stops files-0 before it starts the new one, so two pods never
    // hold the metadata file at once; Parallel lets an apply replace an unready files-0
    updateStrategy: { type: 'RollingUpdate' },
    podManagementPolicy: 'Parallel',
    serviceName: inputs.serviceName,
    selector: { matchLabels: filesLabels },
    template: {
      metadata: { labels: filesLabels },
      spec: {
        securityContext: {
          fsGroup: nonrootID,
          runAsNonRoot: true,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        automountServiceAccountToken: false,
        enableServiceLinks: false,
        imagePullSecrets: [{ name: inputs.pullSecret }],
        volumes: [{ name: 'tmp', emptyDir: {} }],
        containers: [buildFilesContainer(inputs)],
      },
    },
    volumeClaimTemplates: [
      {
        metadata: { name: 'data' },
        spec: {
          accessModes: ['ReadWriteOnce'],

          // keeps the volume when the claim is deleted
          storageClassName: 'local-path-retain',
          resources: { requests: { storage: '20Gi' } },
        },
      },
    ],
  };
}

function buildFilesContainer(inputs: FilesSpecInputs): input.core.v1.Container {
  return {
    name: 'files',
    image: inputs.image,
    ports: [{ name: 'http', containerPort: filesPort }],
    env: [
      { name: 'FILES_PORT', value: String(filesPort) },
      { name: 'FILES_DATA_DIR', value: '/data' },
      { name: 'FILES_PUBLIC_URL', value: inputs.publicURL },
      {
        name: 'FILES_AGENT_TOKEN_SHA256',
        valueFrom: { secretKeyRef: { name: inputs.tokenSecret, key: agentTokenHashKey } },
      },
      {
        name: 'FILES_OWNER_TOKEN_SHA256',
        valueFrom: { secretKeyRef: { name: inputs.tokenSecret, key: ownerTokenHashKey } },
      },
    ],
    readinessProbe: {
      httpGet: { path: '/healthz', port: filesPort },
      periodSeconds: 10,
      failureThreshold: 3,
    },
    livenessProbe: {
      httpGet: { path: '/healthz', port: filesPort },
      periodSeconds: 30,
      failureThreshold: 3,
    },
    volumeMounts: [
      { name: 'data', mountPath: '/data' },
      { name: 'tmp', mountPath: '/tmp' },
    ],
    securityContext: {
      allowPrivilegeEscalation: false,
      readOnlyRootFilesystem: true,
      capabilities: { drop: ['ALL'] },
      runAsUser: nonrootID,
      runAsGroup: nonrootID,
    },

    // an upload is held in memory while it is written, so the limit leaves room for a 100 MB file
    // read from the form and written out
    resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '768Mi' } },
  };
}
