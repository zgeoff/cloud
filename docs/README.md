# Documentation

## Architecture

[The overview](./architecture/overview.md) gives the whole estate on one page: the path of a public
call, the path of a change, the topology and the data.

- [Infrastructure as code](./architecture/infrastructure-as-code.md): the Pulumi program, its
  providers, drift, the apply job and the guards.
- [Secrets](./architecture/secrets.md): how each secret reaches its user, the encryption at rest and
  its accepted risks, and what 1Password cannot restore.
- Host:
  - [The host](./architecture/host/host.md): NixOS, the disks, the services, and how a switch builds
    before it activates.
  - [imp on the host](./architecture/host/imp.md): impd's container, its DNS, and the copy and
    restore of its database.
- Network:
  - [The tailnet](./architecture/network/tailnet.md): the policy file, the tags and their grants,
    SSH.
  - [Firewalls](./architecture/network/firewalls.md): the cloud firewall and the host's nftables
    tables.
  - [Public ingress](./architecture/network/public-ingress.md): the Cloudflare tunnel and its one
    route.
- Workloads:
  - [The atc gateway](./architecture/workloads/atc-gateway.md): the gateway, its daemons, its state
    and its backup.
  - [1Password Connect](./architecture/workloads/onepassword-connect.md): how a granted imp reads
    the vault through a host relay.
  - [nixie](./architecture/workloads/nixie.md): the assistant, its secrets, its definitions, its
    route on the tailnet, and its backup.
  - [The agent image](./architecture/workloads/agent-image.md): what sessions run on, and how it is
    built and pinned.
  - [Previews](./architecture/workloads/preview.md): one imp per pull request, behind a tailnet
    link, and the signed webhook that posts it.
  - [The files service](./architecture/workloads/files.md): token-gated uploads, public reads by
    link, the type rules for serving, expiry and the backup.
  - [Observability](./architecture/workloads/observability.md): metrics, logs, probes, alerts and
    the check from the edge.

## Reference

- [Exposure](./reference/exposure.md): every public route and port, generated from the exposure
  registry.

## Runbooks

- [Development](./runbooks/development.md): set up a machine and run a first preview.
- [Workflows](./runbooks/workflows.md): change infrastructure, switch the host, upgrade imp, rotate
  a credential.
- [Observe](./runbooks/observe.md): Grafana, logs, metrics, the external health check, and Discord
  alerts.
- [The prod apply job](./runbooks/prod-apply.md): set up the job, read a run, answer a held one.
- [The scheduled drift check](./runbooks/drift-check.md): the host's daily check, its credentials, a
  run by hand, and how to answer drift.
- [Troubleshooting](./runbooks/troubleshooting.md): known failures, by message or symptom.
- [Reinstall geoffcloud](./runbooks/reinstall-geoffcloud.md): reinstall the host as NixOS.
- [tank/cloud](./runbooks/tank-cloud.md): create the encrypted datasets, and restore their key.
- [Restore geoff.cloud](./runbooks/restore-geoff-cloud.md): recover imps, impd's database, the host
  or the cluster.
- [Recover a lost disk](./runbooks/lost-disk.md): recover from the loss of `vda`, `vdb` or both.
- [Leak response](./runbooks/leak-response.md): what a leaked snapshot, account, backup or disk
  exposes, and what to revoke.
- [Restore drill](./runbooks/restore-drill.md): restore impd's database and hq on a scratch VM, with
  their measured times, and the untested root-disk snapshot restore.
- [atc gateway backup and restore](./runbooks/atc-gateway-backup-restore.md): back up and restore
  the gateway's state.
- [atc gateway smoke spawn](./runbooks/atc-gateway-smoke.md): spawn a Claude session through the
  gateway onto an imp and check its first turn.
- [The GHCR pull token](./runbooks/ghcr-pull-token.md): rotate the token k3s pulls the private
  images with, and check a pull.
- [Agent image](./runbooks/agent-image.md): build, check, switch or roll back the agent image.
- [1Password Connect](./runbooks/onepassword-connect.md): set up, rotate or debug Connect for imps.
- [nixie](./runbooks/nixie.md): add nixie's images and secrets to impd, change a secret, deploy,
  enrol a device, back up and restore, renew the certificate.
- [nixie's backup](./runbooks/nixie-backup.md): back up nixie now, read the repository, purge a
  forgotten item, test a restore.
- [The files service](./runbooks/files.md): deploy files.geoff.cloud, upload a file, upgrade, revoke
  a token, back up, restore and check a restore.
- [Release check](./runbooks/release-check.md): the bump pull requests for new atc, imp, nixie and
  auto-mode releases, when they merge on their own, and the app they run as.
- [Previews](./runbooks/preview.md): set up the preview service, opt a repository in, check a
  preview live.
- [imp's e2e nodes](./runbooks/imp-e2e-tailnet.md): the tailnet client for imp's end-to-end suites.

Planned work and open choices live in Linear, not in this tree.
