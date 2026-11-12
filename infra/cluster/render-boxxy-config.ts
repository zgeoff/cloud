import { topology } from '@zgeoff/cloud-topology';
import type { BoxxyConfig } from '../inputs/index.ts';

export const boxxyOwnerPort = topology.boxxy.ownerPort;
export const boxxyWorkerPort = topology.boxxy.workerPort;

// the volume holds the store; the atc gateway's backup image copies every *.db in it
const boxxyStoreFile = '/data/boxxy.db';

// the image's own rules folder, which has no .git, so the server loads it as a plain folder
const boxxyRulesFolder = '/rules';

// where the pod mounts the ConfigMap of the trust documents, one file per issuer
export const boxxyTrustedIssuersFolder = '/etc/boxxy-issuers';

interface BoxxyConfigFileInputs {
  readonly config: Pick<BoxxyConfig, 'runner' | 'atc' | 'spawn'>;

  // the oRPC route the server calls atc on: the atc gateway's Service in the cluster
  readonly atcURL: string;

  // true when the pod mounts at least one trust document; with none, the file has no
  // trustedIssuers section, so the server refuses every session and hook call
  readonly trusted: boolean;
}

// The boxxy server's configuration file (its serverConfigSchema), as JSON. It holds no secret: the
// server reads each token from the environment. The audience is the broker's made-up host, which
// the broker's imp identity tokens name.
export function renderBoxxyConfig(inputs: BoxxyConfigFileInputs): string {
  const file = {
    runner: inputs.config.runner,
    store: { file: boxxyStoreFile },
    rules: { folder: boxxyRulesFolder },
    api: {
      listen: { hostname: '0.0.0.0', port: boxxyOwnerPort },
      workerListen: { hostname: '0.0.0.0', port: boxxyWorkerPort },
    },
    spawn: inputs.config.spawn,
    atc: { url: inputs.atcURL, ...inputs.config.atc },
    ...(inputs.trusted
      ? {
          trustedIssuers: {
            folders: [boxxyTrustedIssuersFolder],
            audience: topology.boxxy.brokerHost,
          },
        }
      : {}),
  };

  return `${JSON.stringify(file, null, 2)}\n`;
}
