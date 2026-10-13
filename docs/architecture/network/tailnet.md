# The tailnet

The owner's Tailscale tailnet is the estate's private network: the host, impd and the owner's
devices meet on it, and nothing private is reachable any other way. Pulumi owns the whole tailnet
policy file, so the code in `infra/` is the complete list of who may reach what, and a rule that is
not in the code does not survive the next apply. [Firewalls](./firewalls.md) covers the host's own
filtering of what arrives over the tailnet, and [public ingress](./public-ingress.md) covers the one
public route.

## One file, owned whole

Pulumi's Tailscale `Acl` resource replaces the live policy file with the one the program builds.
That makes the policy reviewable as code, and it makes every apply destructive for a rule someone
added in the admin console. The owner therefore reviews the diff of any preview that changes the
policy before it applies, and a test pins the whole policy object, so a change to it is always a
visible change to the test as well.

## Identities

A tagged node holds only what a grant gives it, while a member's device reaches every device on any
port.

| Identity           | Holder                                         | Reaches                                               |
| ------------------ | ---------------------------------------------- | ----------------------------------------------------- |
| a member's device  | the owner's devices, the PC among them         | every device, on any port; the host's HTTPS for nixie |
| `tag:cloud`        | the host's node, and through it every pod      | the PC's atc daemon; impd's node for HTTPS            |
| `tag:imp`          | impd's node on the host, and imp's dev nodes   | other `tag:imp` nodes' API                            |
| `tag:imp-e2e`      | the throwaway nodes of imp's end-to-end suites | other `tag:imp-e2e` nodes' API only                   |
| `tag:cloud-deploy` | the prod apply job's ephemeral runner node     | the host's k3s API only                               |

A pod has no tailnet identity of its own. Its traffic leaves through the host's node, so the cluster
as a whole is `tag:cloud`, and every pod gains whatever the host is granted. The grants for
`tag:cloud` are therefore single ports to single hosts: the PC's daemon port for the gateway, and
impd's HTTPS port for the cluster's health probe. Each names its destination by a host alias for one
node rather than by a tag, so a later node with the same tag gains nothing.

nixie's pod calls impd's API over the same route, so `tag:cloud` holds a second grant to impd's node
for HTTPS, named in the policy as nixie's route to impd
([nixie](../workloads/nixie.md#reaching-impd)). It matches the probe's grant exactly and gives the
cluster nothing beyond it. Tailscale takes the union of the grants that match a connection, so the
route stays open while either grant stands: a change to the probe's grant leaves nixie's route open,
and removing nixie's grant cuts nixie off from impd once the probe's grant no longer covers the
route.

Members hold a second grant, to the host's HTTPS port for nixie, beside the grant that lets them
reach every device. The policy lists nixie's route in its own grant, so the route stays open if the
wider grant narrows.

impd's nodes reach each other's API only, which is what lets impd move an imp between hosts and
nothing more. The end-to-end nodes reach each other and never a `tag:imp` node, so a test run can
never touch a live impd. They join with keys from an OAuth client of their own, which can mint keys
for that tag alone ([the imp e2e runbook](../../runbooks/imp-e2e-tailnet.md)).

The prod apply job's runner joins for one run as `tag:cloud-deploy`, through a federated identity
that GitHub's token for the job proves, so no key for it is stored anywhere. The runner holds
full-account cloud credentials for the run, so its one grant is the k3s API port on the host, which
Pulumi drives the cluster through, and no SSH rule lists it as a destination
([infrastructure as code](../infrastructure-as-code.md#the-apply-job)).

Each tag owns itself as well as being owned by the tailnet's admins, because Tailscale lets an OAuth
client mint keys only for tags its own tags own. Pulumi's client carries `tag:cloud` and `tag:imp`,
and mints the host's and impd's auth keys with it.

## SSH

Tailscale SSH replaces public SSH to the host. An admin reaches a `tag:cloud` host as root or as any
non-root user with no browser check, because scripts and agents connect unattended and a check would
ask for a browser login again on a timer. A member reaches their own devices with the check. The
host's sshd still runs with keys only, and the cloud firewall keeps its port off the internet
([firewalls](./firewalls.md)).

Tailscale SSH logs each session's full remote command line in the host's journal, and Alloy ships
the journal to Loki, so a secret never travels in an SSH command line ([secrets](../secrets.md)).

## Names

MagicDNS names every node, so the host is `geoffcloud` on the tailnet, and impd's node is
`imp-geoffcloud`. impd's HTTPS names under `imps.geoff.cloud` are public DNS records that point at
that node's tailnet address, so they resolve anywhere and answer only on the tailnet
([imp on the host](../host/imp.md#dns-and-certificates)). nixie's name, `nixie.geoff.cloud`, follows
the same pattern at the host's own tailnet address.
