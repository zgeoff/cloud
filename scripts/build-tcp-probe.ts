export interface ProbeTarget {
  // an IP address, which the probe puts in a command line
  readonly host: string;
  readonly port: number;
}

// A shell command that opens one TCP connection and prints `probe-exit:` with its status: 0 when it
// connects, 1 when it is refused, and 124 when nothing answers within 5 s. bash's /dev/tcp needs
// no tool beyond bash and coreutils, which both the host and nixie's fetch image hold.
export function buildTCPProbe(target: ProbeTarget): string {
  return `timeout 5 bash -c 'exec 3<>/dev/tcp/${target.host}/${target.port}' 2>/dev/null; echo probe-exit:$?`;
}
