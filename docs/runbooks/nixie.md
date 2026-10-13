# nixie

nixie runs in k3s from the stack config `nixie` and the files in `deploy/nixie/`, and answers at
`https://nixie.geoff.cloud` on the tailnet. [nixie](../architecture/workloads/nixie.md) explains the
pods, the secrets and the route. Run the Pulumi steps from a clean checkout of `main`, as
[change infrastructure](./workflows.md#change-infrastructure) describes.

**CAUTION:** The secrets file holds the deployment key, which wraps every key in nixie's key store.
A leaked age key decrypts every earlier commit of the file, so recovery from a leak rotates every
secret the file ever held. Never print a decrypted value, and never put one on a command line.

## What holds what

| Where                                              | Holds                                                           |
| -------------------------------------------------- | --------------------------------------------------------------- |
| vault `cloud`, item `nixie-age-host`               | the age identity that the pod holds; its public half is in sops |
| vault `cloud`, item `nixie-age-recovery`           | the age identity that stays off the host; restores need only it |
| vault `cloud`, item `nixie-deployment-key`         | the deployment key, 32 random bytes in base64                   |
| vault `cloud`, item `nixie-model-credential`       | the Claude setup token behind the model profile `opus`          |
| vault `cloud`, item `nixie-definitions-deploy-key` | git-sync's read-only deploy key for `zgeoff/nixie-definitions`  |
| vault `cloud`, item `nixie-restic`                 | the restic password of nixie's backup repository                |
| vault `cloud`, item `r2-nixie-backup`              | the R2 key, endpoint and bucket of nixie's backup repository    |
| `deploy/nixie/secrets.sops.yaml`                   | the deployment key, the model credential and nixie's impd token |
| impd                                               | the token `nixie`, the model secret and nixie's sandbox images  |

## Set up the helpers

Each step below runs sops from the nixie image of the pinned release, because that is the sops nixie
decrypts with. Run these in the repo root first:

```bash
NIXIE_IMAGE='ghcr.io/zgeoff/nixie:<version>@sha256:<nixie_digest>' # the release to deploy
sops_nixie() {
  SOPS_AGE_KEY="$(op read op://cloud/nixie-age-recovery/credential)" docker run --rm -i \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e SOPS_AGE_KEY -v "$PWD/deploy/nixie:/w" -w /w --entrypoint /usr/local/bin/sops \
    "$NIXIE_IMAGE" "$@"
}
host_imp() { ssh root@geoffcloud docker exec -i imp-host imp "$@"; }
```

`host_imp` sends its standard input over SSH, so a secret piped into it never reaches the host's
journal.

## Add nixie's images and model secret to impd

nixie's token cannot add an image or a secret, so add them as impd's root before the first deploy,
after a release that changes nixie's sandbox images, and after a model credential rotation.

1. Add each sandbox image under the name nixie derives, `nixie-<kind>-<first 12 hex of the digest>`.
   The nixie image lists the images in its sandbox manifest:

   ```bash
   docker run --rm --entrypoint cat "$NIXIE_IMAGE" /app/sandbox-manifest.json \
     | jq -r 'to_entries[] | "\(.value) nixie-\(.key)-\(.value | split("@sha256:")[1][0:12])"' \
     | while read -r ref name; do host_imp image add "$ref" --name "$name" < /dev/null; done
   ```

2. Add a model secret for each profile in `config.yaml`, under the name nixie derives,
   `model-<profile>-<first 16 hex of the SHA-256 of "bearer", the API host and the credential>`.
   Every profile uses the same credential, so the names differ only by profile:

   ```bash
   hash=$(op read op://cloud/nixie-model-credential/credential \
     | { IFS= read -r c; printf 'bearer\napi.anthropic.com\n%s' "$c"; } | sha256sum | cut -c1-16)
   secrets=model-opus-$hash,model-haiku-$hash,model-sonnet-$hash
   for secret in ${secrets//,/ }; do
     op read op://cloud/nixie-model-credential/credential | host_imp secret add "$secret" \
       --kind custom --hosts api.anthropic.com --header authorization --scheme bearer
   done
   ```

   Expect `host_imp secret ls` to list each name with the host `api.anthropic.com`. A profile
   without its secret leaves its role's sandbox unmade, and `imp_host` unready.

## Mint nixie's impd token

The token manages only nixie's imps and grants only the model secrets. Mint it straight into the
secrets file, so its value never prints:

```bash
host_imp token new nixie --scope manage --imps 'nixie-*' --grantable "$secrets" < /dev/null \
  | tr -d '\n' | jq -Rs . | sops_nixie set --value-stdin secrets.sops.yaml '["impd_token"]'
```

impd shows the secret only once, so if the sops step fails, remove the token with
`host_imp token rm nixie < /dev/null` and mint it again.

After a model credential rotation, or after a profile joins `config.yaml`, point the token at the
new list with `host_imp token set nixie --grantable "$secrets" < /dev/null`. The flag takes the
whole list, and a secret left out loses its grants on nixie's imps. Remove an old secret once nixie
runs on the new one.

## Change a secret

Set a value from 1Password on stdin, then commit the file through a PR and apply:

```bash
op read op://cloud/nixie-model-credential/credential | tr -d '\n' | jq -Rs . \
  | sops_nixie set --value-stdin secrets.sops.yaml '["model_credentials"]["anthropic"]'
```

Check that both recipients still decrypt the file, printing only its keys:

```bash
sops_nixie decrypt --output-type json secrets.sops.yaml | jq -c 'keys'
```

Expect `["deployment_key","impd_token","model_credentials"]`. A new host key goes in
`deploy/nixie/.sops.yaml`, followed by `sops_nixie updatekeys -y secrets.sops.yaml`.

## Deploy or upgrade

1. For the first deploy, once the secrets file holds `impd_token`, add the stack config `nixie` in
   one PR. Setting it approves the deploy, and the program creates nothing for nixie without it:

   ```yaml
   geoff-cloud:nixie:
     image: ghcr.io/zgeoff/nixie:<version>@sha256:<nixie_digest>
     webImage: ghcr.io/zgeoff/nixie-web:<version>@sha256:<web_digest>
     hostname: nixie.geoff.cloud
   ```

   For an upgrade, set `image` and `webImage` in the stack config `nixie` to the new release's tag
   and digest, from its release notes, in one PR.

2. Add the release's sandbox images to impd, as above.
3. Preview, then apply:

   ```bash
   bun run preview -- --refresh
   bun run up
   ```

4. Check readiness from the host:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie exec nixie-0 -c nixie -- \
     bun -e 'console.log(await (await fetch("http://127.0.0.1:8080/health/ready")).text())'
   ```

   Expect every part ready. The log line `writer.started` in
   `k3s kubectl -n nixie logs nixie-0 -c nixie` shows the database opened, with its schema version.

5. Check the route from a tailnet device: `curl -sS https://nixie.geoff.cloud/health/live`. Expect
   HTTP 200.

6. Run the deploy checks, as [Check a deploy](#check-a-deploy) describes.

## Check a deploy

Two checks prove a deploy end to end. Run both after each deploy or upgrade of nixie, from a repo
checkout on a tailnet device that reaches `root@geoffcloud` over SSH. They create nothing in the
cluster and write nothing to nixie's conversation, and CI never runs them, because they need the
live host.

**CAUTION:** A check that stops early can leave its session or its imp behind. The stream check
prints the ID of a session it could not revoke: revoke it from nixie's device list. The sandbox
check prints the name of an imp it could not remove: remove it with
`host_imp rm <name> < /dev/null`.

1. Check the live stream through the ingress:

   ```bash
   bun run nixie:check-stream
   ```

   The check enrols a device session with a code from nixie's pod, counts the conversation's
   records, holds the conversation's stream open for 30 s, counts the records again, and revokes the
   session. It sends no message. Expect the last line `stream check passed`, after a `stream held`
   line with at least 5 keepalives and 0 records, and the same count on the `records before` and
   `records after` lines. A message sent from a device during the hold fails the check, so run it
   while nobody uses nixie.

2. Check the fetch sandbox's egress:

   ```bash
   bun run nixie:check-sandbox 100.69.47.33:443
   ```

   The check creates one imp, `fetch-check-<8 hex>`, from nixie's fetch image under imp's `public`
   policy, as nixie's web fetch tool does. The imp must read `https://example.com/`, and must not
   connect to impd, the node's addresses, nixie's pod and Service, or a tailnet address. It removes
   the imp at the end. Expect `public page: https://example.com/ answered 200 true`, every
   `from the sandbox` line `blocked`, and the last line `fetch sandbox check passed`.

   Each target must first connect from the host, because an address with no listener refuses the
   sandbox whatever the firewall does. Pass the tailnet target as the argument, because the check
   has no default: `100.69.47.33:443` is nixie's ingress. To probe another tailnet address, pass it
   with a port that listens: `bun run nixie:check-sandbox <tailnet address>:<port>`.

   The tailnet target must not use port 53, and the check refuses one. imp redirects a public
   sandbox's DNS connections to its own DNS proxy, so a probe of port 53 connects even from a
   correctly isolated sandbox and fails the check. The check also refuses an address outside the
   tailnet's ranges, `100.64.0.0/10` and `fd7a:115c:a1e0::/48`. An address such as loopback reaches
   a different listener from the host than from the sandbox, so the probe would prove nothing.

## Enrol a device

nixie signs a device in with a one-time code:

```bash
ssh root@geoffcloud k3s kubectl -n nixie exec nixie-0 -c nixie -- bun /app/main.js enrol-code
```

Open `https://nixie.geoff.cloud` on the device and enter the code before it expires.

## Reset nixie's data

The reset wipes nixie's state so that a test starts again from an empty database. It stops nixie,
deletes `nixie.db` and `keys.db` with their WAL and SHM files from the data volume, starts nixie
again, and prints a fresh enrolment code.

**CAUTION:** A reset cannot be undone. It deletes every record and key in nixie and signs out every
device, and the reset itself keeps no copy. Run a backup first, as
[nixie's backup](./nixie-backup.md#back-up-now) describes, if any of the data matters.

1. List what the reset deletes. The dry run reads the volume and changes nothing:

   ```bash
   bun run nixie:reset --dry-run
   ```

2. Run the reset:

   ```bash
   bun run nixie:reset --confirm
   ```

   Expect the steps to run in order and the last line to be
   `reset done: enter the code above at https://nixie.geoff.cloud`, after the enrolment code.

3. Enrol each device again: open `https://nixie.geoff.cloud` and enter the code before it expires.
   Every other device needs a code of its own, as [Enrol a device](#enrol-a-device) describes.

Without a flag the script refuses and reaches nothing. A step that fails stops the reset and leaves
the later steps unrun, so nixie can stay at 0 replicas. Fix the cause and run the reset again: every
step is safe to repeat.

## Keep nixie's data out of copies

A forget in nixie removes an item everywhere nixie holds it, but a copy taken outside nixie keeps
it. Three kinds of copy exist, and each has its rule.

### Disk snapshots

Each manual Onidel snapshot of the root disk holds `nixie.db` and `keys.db` in plain form. Delete
each one once the host change it guarded is checked, through `DELETE /snapshots/<snapshot_id>` on
the Onidel API.

### imp backups

nixie creates each sandbox with imp's backup opt-out, so no backup holds a nixie sandbox. A sandbox
made before the opt-out stays backed up until nixie replaces it at its next start. Check the
repository with a helper that runs restic in imp-host with impd's own settings:

```bash
host_restic() {
  ssh root@geoffcloud "docker exec imp-host sh -c 'export RESTIC_REPOSITORY=\$IMP_BACKUP_REPOSITORY RESTIC_PASSWORD_FILE=\$IMP_BACKUP_PASSWORD_FILE; restic $*'" < /dev/null
}
host_restic snapshots --no-lock --json \
  | jq -r '.[] | select(any(.tags[]; startswith("imp=nixie-"))) | .short_id'
host_restic dump --no-lock latest /var/lib/imp/backup/tree/manifest.json \
  | jq -c '[.imps[].name | select(startswith("nixie-"))]'
```

Expect no snapshot ID and `[]`. An `excluded=nixie-<id>` tag is expected, because impd tags each
sandbox that a backup leaves out. If a snapshot holds a nixie sandbox, first check that
`host_imp ls --json` shows `"backup": false` on every `nixie-*` imp, or the next backup brings the
copy back.

**CAUTION:** A forget cannot be undone. It also removes every other imp's copy in that snapshot, so
forget only snapshots older than the newest one that holds no nixie sandbox. Run it away from the
6-hourly backup, because impd unlocks the repository before each run.

```bash
host_restic forget <short_id> <short_id>
host_restic prune
```

### nixie's backup

Each snapshot of nixie's backup holds both databases whole, so a forgotten item stays in R2 until
retention drops the last snapshot taken before the forget.
[Purge a forgotten item](./nixie-backup.md#purge-a-forgotten-item) removes it sooner.

## Restore from a backup

The `nixie-backup` CronJob backs up `nixie.db` and `keys.db` every night to R2, as
[nixie's backup](./nixie-backup.md) describes. A restore also needs the deployment key from the
secrets file, which wraps the record keys in `keys.db`.

**CAUTION:** A restore replaces nixie's records and keys with the snapshot's. Every record and
device enrolled after the snapshot is lost. Back up first if the current data still matters.

1. Stop nixie, so nothing writes during the restore:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie scale statefulset/nixie --replicas=0
   ssh root@geoffcloud k3s kubectl -n nixie wait --for=delete pod/nixie-0 --timeout=120s
   ```

   Expect `pod/nixie-0 condition met`. nixie writes until its pod stops.

2. Restore with `deploy/nixie/restore-job.yaml`, which checks both databases before it replaces
   either. Set `args: ["ls"]` to list the snapshots first, and `SNAPSHOT` to pick one:

   ```bash
   ssh root@geoffcloud k3s kubectl create -f - < deploy/nixie/restore-job.yaml
   ssh root@geoffcloud k3s kubectl -n nixie logs -f job/<job-name>
   ```

   Expect `restored nixie.db: integrity_check ok` and `restored keys.db: integrity_check ok`.

3. Start nixie and check it, as step 4 of [Deploy or upgrade](#deploy-or-upgrade) describes:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie scale statefulset/nixie --replicas=1
   ```

4. Record the restore, with the snapshot ID, the time and the reason, in a cloud issue.

## Renew the certificate

The certificate lives 90 days, and an apply in its last 30 days renews it. Nothing renews it between
applies, so apply at least every 60 days. `bun run preview` shows the Certificate as an update when
an apply would renew it.

## Failures

| Symptom                                           | Cause                                    | Fix                                             |
| ------------------------------------------------- | ---------------------------------------- | ----------------------------------------------- |
| `imp_host` unready, `FORBIDDEN` in logs           | an image or the model secret is missing  | add it, as above                                |
| `definitions` unready                             | git-sync has no checkout yet             | `k3s kubectl -n nixie logs nixie-0 -c git-sync` |
| `definitions` unready for minutes after a start   | nixie seeded before git-sync's checkout  | wait for nixie's next definitions probe         |
| an upgrade's rollout never replaces `nixie-0`     | a rolling update waits on an unready pod | `k3s kubectl -n nixie delete pod nixie-0`       |
| the pod restarts with `sops could not decrypt`    | the host key is not a recipient          | add it to `.sops.yaml` and run `updatekeys`     |
| the pod restarts with `nixie refuses the secrets` | a key is missing from the file           | set it, as above                                |
| TLS error on the name                             | the certificate expired                  | `bun run up`                                    |
| no `nixie-0` pod after a reset                    | the reset stopped after it scaled to 0   | `bun run nixie:reset --confirm` again           |
