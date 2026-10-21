import type { Provider } from '@pulumi/kubernetes';
import { StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { Secret, Service } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import { interpolate } from '@pulumi/pulumi';
import type { FilesInputs } from '../inputs/index.ts';
import { createNamespace } from '../shared/create-namespace.ts';
import {
  agentTokenHashKey,
  buildFilesSpec,
  filesLabels,
  filesPort,
  ownerTokenHashKey,
} from './build-files-spec.ts';
import { ghcrPullSecretName } from './build-ghcr-pull-secret-args.ts';
import { createFilesBackupJob } from './create-files-backup-job.ts';
import { createGHCRPullSecret } from './create-ghcr-pull-secret.ts';

// cloudflared sends every path of hostname to service
export interface FilesRoute {
  readonly hostname: string;
  readonly service: Output<string>;
}

interface FilesOutputs {
  readonly route: FilesRoute;
}

export function createFiles(cluster: Provider, inputs: FilesInputs): FilesOutputs {
  const ns = createNamespace('files', cluster);
  const namespace = ns.metadata.name;

  const pull = createGHCRPullSecret(cluster, {
    resourceName: 'files-ghcr-pull',
    namespace,
    credential: inputs.pullCredential,
  });

  // Pulumi names the Secret and replaces it when a hash changes, so a revoked token rolls the pod
  const tokens = new Secret(
    'files-tokens',
    {
      metadata: { namespace },
      stringData: {
        [agentTokenHashKey]: inputs.tokenHashes.agent,
        [ownerTokenHashKey]: inputs.tokenHashes.owner,
      },
    },
    { provider: cluster },
  );

  // Pulumi skips its wait for ready pods: the StatefulSet updates after the Service it names, so
  // that wait would hold back the rollout that brings them
  const service = new Service(
    'files',
    {
      metadata: {
        name: 'files',
        namespace,
        annotations: { 'pulumi.com/skipAwait': 'true' },
      },
      spec: {
        selector: filesLabels,
        ports: [{ name: 'http', port: filesPort, targetPort: 'http' }],
      },
    },
    { provider: cluster },
  );

  const statefulSet = new StatefulSet(
    'files',
    {
      metadata: { name: 'files', namespace },
      spec: buildFilesSpec({
        image: inputs.config.image,
        publicURL: `https://${inputs.config.hostname}`,
        serviceName: service.metadata.name,
        tokenSecret: tokens.metadata.name,
        pullSecret: ghcrPullSecretName,
      }),
    },
    { provider: cluster, dependsOn: [pull] },
  );

  if (inputs.backup !== undefined) {
    createFilesBackupJob(cluster, { namespace, statefulSet, backup: inputs.backup });
  }

  return {
    route: {
      hostname: inputs.config.hostname,
      service: interpolate`http://${service.metadata.name}.${namespace}.svc.cluster.local:${filesPort}`,
    },
  };
}
