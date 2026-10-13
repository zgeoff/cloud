import { BlockList, isIP } from 'node:net';
import { topology } from '@zgeoff/cloud-topology';
import type { ProbeTarget } from './build-tcp-probe.ts';

// the host's own tailnet address and HTTPS port, as the example target in each message
const exampleTarget = `${topology.tailnet.nodes.geoffcloud.address}:443`;

export type TailnetTargetResult =
  | { readonly ok: true; readonly target: ProbeTarget }
  | { readonly ok: false; readonly error: string };

// Parses the check's arguments: exactly one tailnet address and port, such as the host's on 443, or
// [fd7a:115c:a1e0::5]:443 for IPv6. It has no default, so the caller always names a listener that
// is not on port 53.
export function parseTailnetTarget(args: readonly string[]): TailnetTargetResult {
  const [arg] = args;

  if (arg === undefined) {
    return {
      ok: false,
      error: `give a tailnet address and port to probe, such as ${exampleTarget}`,
    };
  }

  const target = args.length === 1 ? findAddress(arg) : undefined;

  if (target === undefined) {
    return { ok: false, error: `give one tailnet address and port, such as ${exampleTarget}` };
  }

  const refusal = findRefusal(arg, target);

  return refusal === undefined ? { ok: true, target } : { ok: false, error: refusal };
}

// an IP address and port, with an IPv6 address in brackets; undefined for anything else
function findAddress(arg: string): ProbeTarget | undefined {
  const match = /^(?:\[(?<v6>[\da-f:]+)\]|(?<v4>[\d.]+)):(?<port>\d{1,5})$/iu.exec(arg);
  const host = match?.groups?.['v6'] ?? match?.groups?.['v4'] ?? '';
  const port = Number(match?.groups?.['port']);

  return isIP(host) !== 0 && port >= 1 && port <= 65_535 ? { host, port } : undefined;
}

// imp redirects a public sandbox's DNS connections to its own DNS proxy, so a probe of port 53 can
// connect however well the sandbox is isolated, and the check would fail a correct deployment
const dnsPort = 53;

// why the check must not probe a well-formed target; undefined when it may
function findRefusal(arg: string, target: ProbeTarget): string | undefined {
  if (!isTailnetAddress(target.host)) {
    return `cannot probe ${arg}: the address is outside the tailnet's ${topology.tailnet.cidr} and fd7a:115c:a1e0::/48, so the host and the sandbox can each reach a different listener on it and the probe would prove nothing`;
  }

  if (target.port === dnsPort) {
    return `cannot probe ${arg}: imp redirects a public sandbox's DNS connections to its own DNS proxy, so a probe of port 53 can connect even when the sandbox is isolated; pick a tailnet port that is not 53, such as ${exampleTarget}`;
  }

  return undefined;
}

// Tailscale's address ranges; any other address, such as loopback, means something else on the host
// than in the sandbox
const tailnetRanges = new BlockList();

const [tailnetNetwork = '', tailnetPrefix] = topology.tailnet.cidr.split('/');

tailnetRanges.addSubnet(tailnetNetwork, Number(tailnetPrefix), 'ipv4');
tailnetRanges.addSubnet('fd7a:115c:a1e0::', 48, 'ipv6');

function isTailnetAddress(host: string): boolean {
  const family = isIP(host) === 6 ? 'ipv6' : 'ipv4';

  return tailnetRanges.check(host, family);
}
