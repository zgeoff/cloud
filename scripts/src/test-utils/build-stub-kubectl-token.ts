import type { StubAnswer, StubHandler } from './build-stub-runner.ts';

export interface StubKubectlTokenOptions {
  // the admin kubeconfig that the calls must name
  readonly adminKubeconfig: string;
  readonly server: string;
  readonly certificateAuthorityData: string;

  // the token each create mints; unset, the cluster has no nixie-verify account
  readonly token?: string;

  // when the cluster minted its first token, so a duration gives its expiry
  readonly nowMs: number;
}

export interface StubKubectlToken {
  readonly handler: StubHandler;

  // the duration each create asked for
  readonly durations: readonly string[];
}

// kubectl 1.35's answers, recorded against k3s 1.34: `config view` prints the jsonpath's fields,
// `create token --output json` prints the TokenRequest, and a missing account exits 1 with
// `error: failed to create token: serviceaccounts "<name>" not found`.
export function buildStubKubectlToken(
  options: Readonly<StubKubectlTokenOptions>,
): StubKubectlToken {
  const durations: string[] = [];

  return {
    handler: (call) => {
      const [tool, flag, path, ...args] = call.argv;

      const isAdminCall =
        tool === 'kubectl' && flag === '--kubeconfig' && path === options.adminKubeconfig;

      return isAdminCall ? answerCall(options, args, durations) : undefined;
    },
    durations,
  };
}

const clusterJSONPath = String.raw`jsonpath={.clusters[0].cluster.server}{"\n"}{.clusters[0].cluster.certificate-authority-data}`;

function answerCall(
  options: Readonly<StubKubectlTokenOptions>,
  args: readonly string[],
  durations: string[],
): StubAnswer | undefined {
  const line = args.join(' ');

  if (line === `config view --minify --flatten --output ${clusterJSONPath}`) {
    return { stdout: `${options.server}\n${options.certificateAuthorityData}` };
  }

  const duration =
    /^--namespace nixie create token nixie-verify --duration=(?<duration>\S+) --output json$/u.exec(
      line,
    )?.groups?.['duration'];

  if (duration === undefined) {
    return undefined;
  }

  durations.push(duration);

  return options.token === undefined
    ? {
        exitCode: 1,
        stderr: 'error: failed to create token: serviceaccounts "nixie-verify" not found\n',
      }
    : { stdout: buildTokenRequest(options.token, options.nowMs + toMs(duration)) };
}

function buildTokenRequest(token: string, expiresAtMs: number): string {
  const expiresAt = new Date(expiresAtMs).toISOString().replace(/\.\d{3}Z$/u, 'Z');

  return `${JSON.stringify(
    {
      kind: 'TokenRequest',
      apiVersion: 'authentication.k8s.io/v1',
      metadata: { name: 'nixie-verify', namespace: 'nixie' },
      spec: { audiences: ['https://kubernetes.default.svc.cluster.local', 'k3s'] },
      status: { token, expirationTimestamp: expiresAt },
    },
    null,
    4,
  )}\n`;
}

// the two Go duration units the scripts ask for
function toMs(duration: string): number {
  const match = /^(?<count>\d+)(?<unit>[mh])$/u.exec(duration);
  const unitMs = match?.groups?.['unit'] === 'h' ? 3_600_000 : 60_000;

  return Number(match?.groups?.['count'] ?? 0) * unitMs;
}
