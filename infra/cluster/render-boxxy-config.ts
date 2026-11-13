import { topology } from '@zgeoff/cloud-topology';
import type { BoxxyConfig, BoxxyRepos } from '../inputs/index.ts';

export const boxxyOwnerPort = topology.boxxy.ownerPort;
export const boxxyWorkerPort = topology.boxxy.workerPort;
const boxxyDoorPort = topology.boxxy.doorPort;

// The volume holds the store, and the door's auth database beside it, `boxxy-auth.db`; the atc
// gateway's backup image copies and restores every *.db in it.
const boxxyStoreFile = '/data/boxxy.db';

// the image's own rules folder, which has no .git, so the server loads it as a plain folder
const boxxyRulesFolder = '/rules';

// where the pod mounts the ConfigMap of the trust documents, one file per issuer
export const boxxyTrustedIssuersFolder = '/etc/boxxy-issuers';

interface BoxxyConfigFileInputs {
  readonly config: Pick<BoxxyConfig, 'runner' | 'atc' | 'spawn' | 'github' | 'publicDoor'>;

  // the server's spawn.repos, which the stack holds as a secret of their own
  readonly repos: BoxxyRepos;

  // the MCP route the server calls atc on, at the atc gateway's Service in the cluster, and the
  // gateway's public host, which the server sends as Host
  readonly atc: { readonly url: string; readonly host: string };

  // pepys ingest's boxxy route and the pepys API's oRPC route, in the cluster, with the environment
  // whose deploy the stage times count; with none, the file has no pepys section and sends no fact
  readonly pepys?: {
    readonly ingestUrl: string;
    readonly apiUrl: string;
    readonly environment: string;
  };

  // true when the pod mounts at least one trust document; with none, the file has no
  // trustedIssuers section, so the server refuses every session and hook call
  readonly trusted: boolean;
}

// The boxxy server's configuration file (its serverConfigSchema), as JSON. It holds no token: the
// server reads each one from the environment. The audience is the broker's made-up host, which
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
    spawn: { ...inputs.config.spawn, repos: inputs.repos },
    atc: { url: inputs.atc.url, host: inputs.atc.host, ...inputs.config.atc },
    ...(inputs.trusted
      ? {
          trustedIssuers: {
            folders: [boxxyTrustedIssuersFolder],
            audience: topology.boxxy.brokerHost,
          },
        }
      : {}),
    ...(inputs.pepys === undefined ? {} : { pepys: inputs.pepys }),
    ...(inputs.config.github === undefined ? {} : { github: inputs.config.github }),

    // on the pod's loopback, the default, where only the tunnel's sidecar reaches it
    ...(inputs.config.publicDoor === undefined
      ? {}
      : { publicDoor: { port: boxxyDoorPort, ...inputs.config.publicDoor } }),
  };

  return `${JSON.stringify(file, null, 2)}\n`;
}
