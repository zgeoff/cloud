import { isIP } from 'node:net';
import type { SandboxTarget } from './load-sandbox-targets.ts';

export interface ProbeAnswer {
  readonly target: SandboxTarget;

  // the connection's status, or null when the probe did not run
  readonly status: number | null;
}

// One line of the report, such as `node 10.0.0.5:10250 blocked (exit 124)`
export function formatProbeAnswer(answer: ProbeAnswer): string {
  const address =
    isIP(answer.target.host) === 6
      ? `[${answer.target.host}]:${answer.target.port}`
      : `${answer.target.host}:${answer.target.port}`;

  return `${answer.target.role} ${address} ${formatStatus(answer.status)}`;
}

function formatStatus(status: number | null): string {
  if (status === null) {
    return 'probe did not run';
  }

  return status === 0 ? 'connected' : `blocked (exit ${status})`;
}
