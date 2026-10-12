# imp on the host

impd, imp's daemon, runs every imp on the host as a Firecracker microVM, and it runs as imp ships
it: one `imp-host` container on the host's Docker, set up by imp's NixOS module. impd schedules its
own microVMs, needs KVM and a ZFS pool, and runs its own tailnet node, so it sits outside k3s. Its
state is one SQLite database and a set of secret files on its own ZFS dataset, and this repo's part
is to pin it, wire it to the host and keep a copy of that database before every upgrade.
[The host](./host.md) covers the disks and the switch, and [secrets](../secrets.md) covers how
impd's secret files arrive.

## Two pins

The host pins imp twice, and an upgrade moves both together. The flake pins imp's NixOS module,
which sets up the container, its units and its firewall table. The module's default image is the
`imp-host` tag of the module's own release, and the host's configuration pins that image by digest
as well, so a tag that is pushed again can never change what runs. The two pins must name the same
release, because a mismatched pair would run one release's daemon under another release's module.

## How impd is reached

impd serves its API on the host's loopback and on its own tailnet node, `imp-geoffcloud`, tagged
`tag:imp`. The cloud daemon and the health probe use the loopback, so neither needs a tailnet grant
to impd. The tailnet node serves impd's API and each imp over HTTPS at `imps.geoff.cloud` and
`<name>.imps.geoff.cloud` ([the tailnet](../network/tailnet.md)).

impd reaches the host's Docker only through imp's Docker API proxy, a separate unit with no network
that forwards the calls impd needs, so the container never mounts the Docker socket. The module also
loads the `inet imp-forward` table, which drops traffic from imp-host's bridge to the cluster's pod
and service ranges, because an imp is an agent sandbox and must not reach a workload
([firewalls](../network/firewalls.md)).

impd holds the host's memory budget for imps and refuses a boot that would exceed it, while an idle
imp sleeps to disk and frees its memory. The ZFS cache has a cap of its own, so the pool and the
imps never compete for the rest of the host's memory.

## DNS and certificates

impd owns the DNS records for its hostnames. It writes DNS-only records for `imps.geoff.cloud` and
`*.imps.geoff.cloud` at the tailnet address of its own node, `imp-geoffcloud`, so the names resolve
publicly but answer only on the tailnet, and it gets a wildcard certificate through Cloudflare's
DNS-01 challenge with a token scoped to that job. Pulumi never declares these records or the
challenge record, because impd rewrites them at run time and an apply would undo its work. impd
rereads the token file when it changes, so a rotation needs no restart. `imp.geoff.cloud` stays free
for imp's own public endpoint.

## The database

impd's database is SQLite in WAL mode on the dataset `tank/imp`, which mounts only inside imp-host,
so the host's own view of impd's state directory is empty. WAL mode means the database file alone is
never a consistent copy while impd runs: a tar of the live files can catch the main file and its log
at different moments. A copy therefore runs inside the container, with SQLite's `VACUUM INTO`, which
writes one consistent file while impd keeps writing. The copy script checks the copy's integrity on
the host and records, beside it, the newest migration it holds, the imp version and the exact
`imp-host` image that wrote it ([copying the database](../../runbooks/workflows.md#upgrade-imp)).

A restore is one-way, because impd's migrations run forward only: a database restored under a newer
impd than wrote it is migrated forward again at start, and an older impd cannot read a newer one.
The restore script therefore pairs the copy with the NixOS generation whose image matches the copy's
record, and it fails closed:

1. It checks every precondition with impd stopped, and changes nothing if one fails.
2. It saves the stopped database, its WAL files and impd's secrets, and checks the saved copies.
3. It stages the copy beside the database, checks it there, and replaces the database with one
   rename.
4. It unmounts the dataset cleanly, activates the matching generation, starts imp-host and checks
   that it runs the copy's image.

A NixOS switch can restart a unit masked at run time, because the units in `/etc` take precedence
over the runtime ones, so the script never relies on a mask to hold impd down.
[The restore runbook](../../runbooks/restore-geoff-cloud.md#2-roll-impds-database-back) gives the
steps and what a restore loses.

## Backups

impd backs each imp up to R2 with restic, under its own password, and a restore of imps runs through
impd ([the restore runbook](../../runbooks/restore-geoff-cloud.md#1-restore-imps-from-restic)). An
imp created with the backup opt-out stays out of every backup for its life. nixie creates each of
its sandboxes that way, so a forget in nixie leaves no copy in R2. The copies of impd's database
stay on the host's root disk, so an Onidel snapshot of the root disk carries them too. The pool
itself has no backup of its own beyond what impd backs up.
