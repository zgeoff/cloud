import { isIP } from 'node:net';
import type { SandboxTarget } from './load-sandbox-targets.ts';

export interface ProbeAnswer {
  readonly target: SandboxTarget;

  // the connection's status, or null when the probe did not run
  readonly status: number | null;
}

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

  if (status === 0) {
    return 'connected';
  }

  return isBlocked(status) ? `blocked (exit ${status})` : `probe failed (exit ${status})`;
}

function isBlocked(status: number): boolean {
  // 1 is a refused or unreachable connection and 124 a timeout; any other status, such as 127
  // for a missing tool, proves nothing about the network
  return status === 1 || status === 124;
}
