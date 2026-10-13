interface TailnetGrant {
  readonly src: readonly string[];
  readonly dst: readonly string[];
  readonly ip: readonly string[];
}

export interface TailnetPolicy {
  readonly hosts: Readonly<Record<string, string>>;
  readonly grants: readonly TailnetGrant[];
}

// A user's device carries its owner's roles and no tags; a tagged node carries tags and no roles
export interface TailnetNode {
  readonly ip: string;
  readonly roles: readonly ('admin' | 'member')[];
  readonly tags: readonly string[];
}

// The protocols ip '*' covers, which are the only ones a test asks about
export interface TailnetConnection {
  readonly proto: 'tcp' | 'udp' | 'icmp' | 'ipv6-icmp';
  readonly port: number;
}

export interface TailnetFilter {
  readonly canConnect: (
    source: TailnetNode,
    destination: TailnetNode,
    connection: TailnetConnection,
  ) => boolean;
}

// Stand-in for the tailnet's packet filter, from Tailscale's grants and policy syntax docs and
// tailscale/tailscale's wgengine/filter (checked 2026-10-13). It throws on syntax it leaves out,
// and never allows ICMP that no grant names, so it never allows more than the tailnet does.
export function buildStubTailnetFilter(policy: TailnetPolicy): TailnetFilter {
  return {
    canConnect: (source, destination, connection) =>
      policy.grants.some(
        (grant) =>
          grant.src.some((selector) => isSelected(policy, selector, source)) &&
          grant.dst.some((selector) => isSelected(policy, selector, destination)) &&
          grant.ip.some((entry) => isAllowedByEntry(entry, connection)),
      ),
  };
}

// A role autogroup selects a user's device whose owner holds the role, never a tagged node
const autogroupRoles: Readonly<Record<string, 'admin' | 'member'>> = {
  'autogroup:admin': 'admin',
  'autogroup:member': 'member',
};

function isSelected(policy: TailnetPolicy, selector: string, node: TailnetNode): boolean {
  const role = autogroupRoles[selector];

  if (selector === '*') {
    return true;
  }

  if (role !== undefined) {
    return node.tags.length === 0 && node.roles.includes(role);
  }

  if (selector.startsWith('tag:')) {
    return node.tags.includes(selector);
  }

  return node.ip === getHostIP(policy, selector);
}

function getHostIP(policy: TailnetPolicy, selector: string): string {
  const hostIP = policy.hosts[selector];

  if (hostIP === undefined) {
    throw new Error(`the stand-in does not model the selector ${selector}`);
  }

  return hostIP;
}

function isAllowedByEntry(entry: string, connection: TailnetConnection): boolean {
  const [proto = '', ports = ''] = entry.split(':');

  if (entry === '*') {
    return true;
  }

  if (getProtoNumber(proto) !== getProtoNumber(connection.proto)) {
    return false;
  }

  return ports === '*' || isInPortRange(entry, ports, connection.port);
}

// IANA protocol numbers for the names a policy may use in ip
const protoNumbers: Readonly<Record<string, number>> = {
  icmp: 1,
  tcp: 6,
  udp: 17,
  'ipv6-icmp': 58,
};

function getProtoNumber(proto: string): number {
  const number = /^\d+$/u.test(proto) ? Number(proto) : protoNumbers[proto];

  if (number === undefined) {
    throw new Error(`the stand-in does not model the protocol ${proto}`);
  }

  return number;
}

// ports is one port or an inclusive range, first-last
function isInPortRange(entry: string, ports: string, port: number): boolean {
  const [first, last = first] = ports.split('-').map(Number);

  if (first === undefined || Number.isNaN(first) || Number.isNaN(last)) {
    throw new Error(`the stand-in does not model the ip entry ${entry}`);
  }

  return port >= first && port <= last;
}
