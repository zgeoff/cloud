import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';

// nixie's API and health port in the pod
export const nixieAPIPort = 8080;
export const nixieLabels = { app: 'nixie' };

// the keys of nixie's Secret: the sops file and the host's age identity that decrypts it
export const nixieSecretsFileKey = 'secrets.yaml';
export const nixieAgeKeyKey = 'age-key.txt';

// the keys of git-sync's Secret: the definitions deploy key and GitHub's pinned host key
export const definitionsDeployKeyKey = 'ssh';
export const definitionsKnownHostsKey = 'known_hosts';

// the key of nixie's ConfigMap, mounted as /etc/nixie/config.yaml
export const nixieConfigKey = 'config.yaml';

// GitHub's ed25519 host key, from https://api.github.com/meta (ssh_keys), checked 2026-10-12. The
// host blocks outbound port 22, so git-sync reaches GitHub's SSH on 443, which serves the same key
export const githubKnownHosts =
  '[ssh.github.com]:443 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n';

// git-sync v4.7.1, by digest; bump deliberately
const gitSyncImage =
  'registry.k8s.io/git-sync/git-sync:v4.7.1@sha256:c5e1976da735bf0b53979f079a07475d77174c51863cd084e928ff6074480717';

const definitionsRoot = '/etc/nixie/definitions';

export interface NixieSpecInputs {
  // the nixie image, by tag and digest
  readonly image: string;

  // the Service that governs the StatefulSet
  readonly serviceName: Output<string>;
  readonly configMap: Output<string>;
  readonly secret: Output<string>;
  readonly definitionsSecret: Output<string>;
}

// nixie's StatefulSet spec: one replica, because SQLite takes one writer, on a ReadWriteOnce volume
// that outlives its claim. git-sync clones the definitions every minute into a shared volume; only
// git-sync mounts the deploy key, and only nixie mounts the age identity.
export function buildNixieSpec(inputs: NixieSpecInputs): input.apps.v1.StatefulSetSpec {
  return {
    replicas: 1,

    // a StatefulSet's rolling update stops nixie-0 before it starts the new one, so two pods never
    // hold the database at once
    updateStrategy: { type: 'RollingUpdate' },

    // OrderedReady stops a rollout while nixie-0 is unready, so an apply that fixes it waits until
    // someone deletes the pod; with one replica, Parallel still stops nixie-0 before its replacement
    podManagementPolicy: 'Parallel',
    serviceName: inputs.serviceName,
    selector: { matchLabels: nixieLabels },
    template: {
      metadata: { labels: nixieLabels },
      spec: {
        // nixie's step grace, so a stop lets its steps in flight commit
        terminationGracePeriodSeconds: 60,

        // fsGroup is a supplementary group of both containers: git-sync reads its Secret and
        // nixie reads git-sync's checkout through it
        securityContext: {
          fsGroup: 10_001,
          runAsNonRoot: true,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        volumes: [
          { name: 'config', configMap: { name: inputs.configMap } },
          { name: 'secrets', secret: { secretName: inputs.secret, defaultMode: 0o440 } },
          {
            name: 'definitions-key',
            secret: { secretName: inputs.definitionsSecret, defaultMode: 0o440 },
          },
          { name: 'definitions', emptyDir: {} },
          { name: 'tmp', emptyDir: {} },
          { name: 'git-sync-tmp', emptyDir: {} },
        ],
        containers: [buildNixieContainer(inputs.image), buildGitSyncContainer()],
      },
    },
    volumeClaimTemplates: [
      {
        metadata: { name: 'data' },
        spec: {
          accessModes: ['ReadWriteOnce'],

          // keeps the volume when the claim is deleted; nixie.db and keys.db live here
          storageClassName: 'local-path-retain',
          resources: { requests: { storage: '10Gi' } },
        },
      },
    ],
  };
}

const lockedDown: input.core.v1.SecurityContext = {
  allowPrivilegeEscalation: false,
  readOnlyRootFilesystem: true,
  capabilities: { drop: ['ALL'] },
};

function buildNixieContainer(image: string): input.core.v1.Container {
  return {
    name: 'nixie',
    image,
    ports: [{ name: 'http', containerPort: nixieAPIPort }],

    // the image's user has no home, so sops finds the host's age identity only through this
    env: [{ name: 'SOPS_AGE_KEY_FILE', value: `/etc/nixie/age/${nixieAgeKeyKey}` }],

    // the health endpoint listens once migrations and the integrity check finish
    startupProbe: {
      httpGet: { path: '/health/live', port: nixieAPIPort },
      periodSeconds: 5,
      failureThreshold: 60,
    },
    livenessProbe: {
      httpGet: { path: '/health/live', port: nixieAPIPort },
      periodSeconds: 30,
      failureThreshold: 3,
    },

    // nixie answers readiness from memory and reports a slow dependency as degraded with a 200, so
    // only a process that cannot serve fails it; 5 s rides out a host short of CPU
    readinessProbe: {
      httpGet: { path: '/health/ready', port: nixieAPIPort },
      periodSeconds: 10,
      timeoutSeconds: 5,
      failureThreshold: 3,
    },
    volumeMounts: [
      { name: 'data', mountPath: '/data' },
      {
        name: 'config',
        mountPath: `/etc/nixie/${nixieConfigKey}`,
        subPath: nixieConfigKey,
        readOnly: true,
      },
      {
        name: 'secrets',
        mountPath: `/etc/nixie/${nixieSecretsFileKey}`,
        subPath: nixieSecretsFileKey,
        readOnly: true,
      },
      {
        name: 'secrets',
        mountPath: `/etc/nixie/age/${nixieAgeKeyKey}`,
        subPath: nixieAgeKeyKey,
        readOnly: true,
      },
      { name: 'definitions', mountPath: definitionsRoot, readOnly: true },
      { name: 'tmp', mountPath: '/tmp' },
    ],
    securityContext: { ...lockedDown, runAsUser: 10_001, runAsGroup: 10_001 },
    resources: { requests: { cpu: '100m', memory: '256Mi' }, limits: { memory: '1Gi' } },
  };
}

// git-sync's flags as its GITSYNC_ variables: the checkout lands under the shared volume, and
// nixie reads the `current` link, which git-sync swaps in one rename
function buildGitSyncContainer(): input.core.v1.Container {
  return {
    name: 'git-sync',
    image: gitSyncImage,
    env: [
      { name: 'GITSYNC_REPO', value: 'ssh://git@ssh.github.com:443/zgeoff/nixie-definitions.git' },
      { name: 'GITSYNC_REF', value: 'main' },
      { name: 'GITSYNC_ROOT', value: definitionsRoot },
      { name: 'GITSYNC_LINK', value: 'current' },
      { name: 'GITSYNC_PERIOD', value: '60s' },
      { name: 'GITSYNC_DEPTH', value: '1' },
      { name: 'GITSYNC_SSH_KEY_FILE', value: `/etc/git-secret/${definitionsDeployKeyKey}` },
      { name: 'GITSYNC_SSH_KNOWN_HOSTS', value: 'true' },
      {
        name: 'GITSYNC_SSH_KNOWN_HOSTS_FILE',
        value: `/etc/git-secret/${definitionsKnownHostsKey}`,
      },
    ],
    volumeMounts: [
      { name: 'definitions', mountPath: definitionsRoot },
      { name: 'definitions-key', mountPath: '/etc/git-secret', readOnly: true },
      { name: 'git-sync-tmp', mountPath: '/tmp' },
    ],

    // the image's own user
    securityContext: { ...lockedDown, runAsUser: 65_533, runAsGroup: 65_533 },
    resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
  };
}
