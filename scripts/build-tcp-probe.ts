export interface ProbeTarget {
  // an IP address, which the probe puts in a command line
  readonly host: string;
  readonly port: number;
}

export function buildTCPProbe(target: ProbeTarget): string {
  // bash's /dev/tcp needs no tool beyond bash and coreutils, which both the host and nixie's
  // fetch image hold
  return `timeout 5 bash -c 'exec 3<>/dev/tcp/${target.host}/${target.port}' 2>/dev/null; echo probe-exit:$?`;
}
