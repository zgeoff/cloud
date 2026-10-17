# Firewalls

Four layers filter traffic to the host, and each covers a gap in the one before it. Onidel's cloud
firewall, outside the VM, admits only Tailscale's port and ICMP from the internet. NixOS's own
nftables table filters what reaches the host and what it forwards, and trusts the tailnet and the
cluster's interfaces. A table of this repo's own narrows two ports that the trusted interfaces would
otherwise leave open, and imp adds tables that keep its imps away from the cluster.
[The tailnet](./tailnet.md) covers who may reach the host over the tailnet in the first place.

## The cloud firewall

Onidel's cloud firewall sits outside the VM, so it holds even when the host's own rules are wrong.
Pulumi declares it as a firewall group whose rules admit Tailscale's direct-connection port and
ICMP. The group closes every port it does not list, but only once it is attached to the VM. The
program attaches it when the stack config says the host answers on the tailnet, and drops the
group's public SSH rule at the same moment, so public SSH lasts only as long as a new host needs it
to come up on the tailnet.

## The host's tables

The host runs nftables with several tables side by side, so NixOS never flushes the whole ruleset on
a reload, because a flush would delete the tables that imp, k3s and Docker load:

| Table              | Loaded by    | Job                                                          |
| ------------------ | ------------ | ------------------------------------------------------------ |
| `inet nixos-fw`    | NixOS        | the host's input and forward firewall                        |
| `inet cloud_host`  | this repo    | narrows the atc daemon's port and the Connect relay's port   |
| `inet imp-forward` | imp's module | drops traffic from imp-host's bridge to the cluster's ranges |
| `inet imp_egress`  | imp-host     | each imp's egress policy, inside the imp-host container      |

k3s and Docker load their own tables as well, for the cluster's networking and the containers'
bridge.

### NixOS's table

NixOS's table admits nothing from the public interface but Tailscale's port and ICMP. ICMP stays
open because path MTU discovery needs ICMP's fragmentation-needed and ICMPv6's packet-too-big
messages, and ping checks that the host is reachable. OpenSSH's NixOS module opens its port on every
interface by default, so the host turns that off, and sshd answers only through the trusted tailnet
interface. It trusts the tailnet interface and the cluster's pod and overlay interfaces as sources,
because pods reach the API server and the kubelet on the host, and the tailnet is already filtered
by the policy. It filters forwarded traffic too, so no public packet reaches a pod or a NodePort,
and it forwards the pods' own traffic. It does not trust Docker's bridge, so a container on it
reaches the host only on the one port opened there, the Connect relay's.

### The narrowing table

Trusting the tailnet interface has a cost: the atc daemon listens on the host's tailnet address, so
NixOS's table alone would admit the daemon's port from every tailnet device the policy lets reach
the host, and every member's device can reach it. This repo's table runs before NixOS's and admits
the daemon's port only from a pod address arriving on the pod interface, which is the path the
gateway's traffic takes to the host's own address. It drops the port from every other source, the
tailnet and the host's loopback included. A drop in any input chain is final, and an accept here
only passes the packet on to NixOS's table, which trusts the pod interface.

The same table admits the Connect relay's port only from Docker's subnet on Docker's bridge, so only
a container on the host reaches the relay
([1Password Connect](../workloads/onepassword-connect.md)). Both rules are narrower than the trust
they sit under, and neither stops a pod on the host from reaching the daemon's port: the daemon's
bearer token is the gate for that.

### imp's tables

imp's module loads a table that drops new flows from imp-host's bridge to the cluster's pod and
service ranges, because an imp is an agent sandbox and must not reach a workload. The same drop is
why imp-host cannot reach 1Password Connect's Service itself, and the host relays the requests for
it. impd keeps each imp's egress policy in a table of its own inside the imp-host container, outside
the host's view.

## The exposure registry

The exposure registry in the topology package lists every public route and port, and each port the
host keeps to the tailnet or to itself, with its scope and its reason. Each part of the estate that
opens something reads the registry instead of its own list, and a check compares the rest with it,
so a port or a hostname cannot go public without an entry that records why. The registry's
[reference table](../../reference/exposure.md) is generated from it.

| Kind               | Read by                                                                  | Checked by                                                     |
| ------------------ | ------------------------------------------------------------------------ | -------------------------------------------------------------- |
| host port          | the host's public ports and admissions, edge rules, nixie's ingress port | the `exposure` NixOS check, against the evaluated host config  |
| tunnel hostname    | the tunnel's routes                                                      | the Pulumi program, which refuses a hostname not listed public |
| tailnet capability | nothing                                                                  | nothing                                                        |
| Worker URL         | nothing                                                                  | nothing                                                        |

The `exposure` check reads NixOS's evaluated firewall and fails on any difference in either
direction. A port open on every interface needs a public entry, and a tailnet entry's port open
there, such as OpenSSH's default, fails the check. A port open on one interface, or narrowed by the
narrowing table, needs a host-scope entry for that interface. An interface with a default route or a
static address faces outside the host, so a port open there needs a public entry, and no host-scope
entry may name it. Each port that imp's module publishes for public imps passes NixOS's input chain
through Docker's forwarding, so it needs a public entry as well. A port range or a hand-written
input rule cannot be matched with an entry, so the check fails on either. A tailnet capability entry
and a Worker URL entry each record a decision that no code reads.

Each public route, which is a public entry of any kind but a host port, names its auth layer: the
part that authenticates each call it carries, such as the workload's own OAuth server or a webhook's
signature. A route that goes public later reuses an auth layer that another entry holds where one
fits, instead of inventing its own. The registry's schema refuses a public route without an auth
layer, and any other entry that names one. The topology package parses the registry when it loads,
so the Pulumi program fails before it plans a resource, and so does every script that reads the
registry. A public host port names its edge rule instead, because Onidel's edge firewall and the
host's own firewall decide who reaches it.

## NodePorts

kube-proxy routes a NodePort through forwarding rather than input, so the input firewall never sees
it. k3s therefore binds NodePorts to the tailnet's address range only, and Grafana's NodePort
answers on the host's tailnet address and nowhere else
([observability](../workloads/observability.md)).
