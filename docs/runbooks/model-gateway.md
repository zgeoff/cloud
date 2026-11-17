# The model gateway

nixie's model gateway runs on the host as the `model-gateway` unit, from the release binary that
[`nixos/packages/model-gateway.nix`](../../nixos/packages/model-gateway.nix) pins. Every model
request of production nixie passes it: imp-host's broker sends each request of a nixie sandbox to
the gateway's model listener, the gateway counts the reply's dollars and tokens in a day and a month
that reset at midnight in nixie's time zone, and it refuses every request once a count reaches the
limit nixie set. nixie sets its limits on the control listener, and the gateway refuses any limit
above the caps in its own config.
[nixie's model gateway](https://github.com/zgeoff/nixie/blob/main/docs/architecture/policy/model-gateway.md)
describes the gateway, and
[`nixos/modules/model-gateway.nix`](../../nixos/modules/model-gateway.nix) describes the unit, its
listeners and their firewall paths.

**CAUTION:** The gateway fails closed. While it is stopped, while its store is unreadable, and while
the lost mark stands, every model request of nixie fails. Never stop the unit while nixie works,
outside a host switch.

## What holds what

| Where                                                                   | Holds                                                                     |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| vault `cloud`, item `model-gateway-control`, field `credential`         | the control token, 64 hex characters                                      |
| `/var/lib/tank-cloud/host-secrets/model-gateway/control-token`          | the same token on the host, mode 0400 root, which the unit loads          |
| `deploy/nixie/secrets.sops.yaml`, key `["settings"]["gateway-control"]` | nixie's copy of the control token, which nixie sends to the control relay |
| `/var/lib/model-gateway/store.json`                                     | the counts, the limits nixie set, each sandbox's count, the lost mark     |
| `/var/lib/model-gateway/override.json`                                  | the limit past a cap that `model-gateway raise` wrote, when one exists    |
| `services.model-gateway` in `nixos/hosts/geoffcloud/configuration.nix`  | the zone, the caps and one priced route per nixie model profile           |

The unit runs as the user `model-gateway`, which owns `/var/lib/model-gateway` with mode 0700.

## Set up the control token

Run these once, before the first switch that enables the unit. The unit starts only once the token
file exists, so a switch before step 2 skips the unit.

1. Create the item from a random token, which never reaches a command line or the screen:

   ```bash
   openssl rand -hex 32 | jq -R '{title: "model-gateway-control", category: "API_CREDENTIAL",
     fields: [{id: "credential", label: "credential", type: "CONCEALED", value: .}]}' \
     | op item create --vault cloud - > /dev/null
   ```

2. Install the token on the host. It travels on SSH's standard input, so the host's journal never
   holds it:

   ```bash
   op read op://cloud/model-gateway-control/credential | tr -d '\n' | ssh root@geoffcloud \
     'install -d -m 0700 /var/lib/tank-cloud/host-secrets/model-gateway && (umask 377 && cat > /var/lib/tank-cloud/host-secrets/model-gateway/control-token) && test -s /var/lib/tank-cloud/host-secrets/model-gateway/control-token && echo ok'
   ```

   Expect `ok`.

3. Compare the first 8 hex of each copy's SHA-256:

   ```bash
   op read op://cloud/model-gateway-control/credential | tr -d '\n' | sha256sum | cut -c1-8
   ssh root@geoffcloud 'sha256sum < /var/lib/tank-cloud/host-secrets/model-gateway/control-token | cut -c1-8' < /dev/null
   ```

   Expect the same 8 characters twice.

## Read the status

The script reads the token on the host and passes it to curl on standard input, so neither the
command line nor the journal holds it:

```bash
ssh root@geoffcloud bash -s <<'EOF'
printf 'Authorization: Bearer %s\n' "$(cat /var/lib/tank-cloud/host-secrets/model-gateway/control-token)" \
  | curl -sS -H @- http://127.0.0.1:8790/status
EOF
```

Expect JSON with the zone `Australia/Sydney`, each period's `start`, `spent`, `limit` and `cap`,
`"lost": false` and `"tripped": null`. `limit` is null until nixie sets it at its start. While a
period's limit is null, the gateway refuses every model request with a 503.

Check the listeners with `ssh root@geoffcloud 'ss -ltn' < /dev/null`. Expect `10.88.0.1:8789`, the
model listener, `127.0.0.1:8790`, the control listener, and the relay's socket on the host's tailnet
address at port 8791.

## Raise a period past its cap

The control listener refuses a limit above a cap. To let nixie spend past it for the current day or
month, write the override as the unit's user, so the gateway can read the file:

```bash
ssh root@geoffcloud 'runuser -u model-gateway -- model-gateway raise --config "$(systemctl show -P ExecStart model-gateway | grep -o "/nix/store/[^ ]*model-gateway.yaml")" --period day --dollars 200 --tokens 250000000' < /dev/null
```

Expect a JSON line with the event `override.written`, the period, its start and the limit. The
gateway reads the override before each request and ignores it once its period ends. To raise for
good, change the caps in the host config and switch the host.

## Clear the lost mark

The gateway writes `"lost": true` into the store when its count fell behind the spend, such as after
a reply that it could not count. While the mark stands, it refuses every request with a 503, across
restarts.

**CAUTION:** The store then holds less than the model API billed. Read `journalctl -u model-gateway`
for the cause, and check the provider's usage page, before you clear the mark.

1. Stop the unit, so no reply writes the store during the edit:
   `ssh root@geoffcloud systemctl stop model-gateway < /dev/null`.
2. Remove the field, keeping the file's owner and mode:

   ```bash
   ssh root@geoffcloud 'cd /var/lib/model-gateway && jq "del(.lost)" store.json > store.json.new && chown model-gateway:model-gateway store.json.new && chmod 0600 store.json.new && mv store.json.new store.json' < /dev/null
   ```

3. Start the unit: `ssh root@geoffcloud systemctl start model-gateway < /dev/null`, and read the
   status. Expect `"lost": false`.

## Send nixie's model requests through the gateway

nixie sends its model requests through the gateway when two halves agree: each `nixie-model-*`
secret in impd has the gateway's model listener as its upstream, and nixie's config sets
`spendStop`. Either half alone stops every model call: an older nixie's sandboxes lose their grants
when the secrets change, and a nixie with `spendStop` refuses to create a sandbox whose secret sends
anywhere else. So change the secrets while no nixie pod runs a turn, during the roll that brings the
config.

impd treats the upstream as part of a secret's binding, so the change needs `--replace --rebind`. A
rebind drops every grant on the secret, and the token's list from before the rebind no longer covers
it, so the token's list is set again after it
([imp's rotate or rebind](https://github.com/zgeoff/impz/blob/main/docs/guides/connectors.md#rotate-or-rebind)).

**CAUTION:** Model calls fail from the rebind until the new pod grants its sandboxes again, about a
minute. Run this when no task works, and never send a test turn to production nixie.

1. Set the helpers and `secret_names` and `secrets`, as
   [nixie's runbook](./nixie.md#add-nixies-model-secrets-to-impd) step 1 does.
2. Write the rebind as a function, to run at the right moment:

   ```bash
   rebind_model_secrets() { # $1: the upstream, or empty for none
     printf '%s\n' "$secret_names" | while IFS= read -r secret; do
       op read op://cloud/nixie-model-credential/credential | tr -d '\n' | host_imp secret add "$secret" \
         --kind static --hosts api.anthropic.com --header authorization --scheme bearer \
         ${1:+--upstream "$1"} --replace --rebind
     done
     host_imp token set nixie --grantable "$secrets" < /dev/null
   }
   ```

3. Merge the PR that sets `spendStop`. The `Deploy prod` run holds it, because it changes
   `deploy/nixie/config.yaml`. Read the held plan, as
   [Answer a held run](./prod-apply.md#answer-a-held-run) describes: expect nixie's ConfigMap and
   Secret replaced and the StatefulSet updated, and nothing else.
4. Dispatch the run, and watch `nixie-0`:

   ```bash
   bun run ops:deploy-prod -- <full commit of main's tip>
   ssh root@geoffcloud k3s kubectl -n nixie get pod nixie-0 -w < /dev/null
   ```

5. When `nixie-0` shows `Terminating`, run `rebind_model_secrets http://10.88.0.1:8789`. Expect a
   table row for each secret, then the token's row.
6. Check, once the new pod is ready:
   - `host_imp secret ls < /dev/null | grep '^nixie-model-'` shows each secret with
     `api.anthropic.com -> http://10.88.0.1:8789`;
   - [the status](#read-the-status) shows the limits nixie set and `"tripped": null`;
   - nixie's log holds no `spend.stop_tripped` and no `spend.limits_unsent` after its first poll;
   - the status's `spent` rises as nixie works.

## Roll back the spending stop

- **nixie lost model access, with no pause:** revert the PR that set `spendStop`, merge it, and
  dispatch its held run. Without `spendStop`, nixie keeps each sandbox it has and never grants it
  again, so the rollback restores the grants that the rebind drops:
  1. Before the rollout, save each sandbox's model grants:

     ```bash
     grants=$(host_imp secret ls --json < /dev/null \
       | jq -r '.[] | select(.name | startswith("nixie-model-")) | .name as $secret | .imps[] | "\(.) \($secret)"')
     ```

  2. When `nixie-0` shows `Terminating`, run `rebind_model_secrets` with no argument, which removes
     the upstream.
  3. Grant each saved pair again, with no path filter, which only the gateway needs:

     ```bash
     printf '%s\n' "$grants" | while read -r imp secret; do
       [ -n "$imp" ] && host_imp grant "$imp" "$secret" < /dev/null
     done
     ```

     Expect `host_imp secret ls` to list each saved imp under its secret again.
- **nixie came up paused with the cause `spending`:** fix the cause first. `unreachable` means nixie
  cannot reach the control relay: check the relay's socket, the firewall admission and nixie's
  network policy. A limit trip at the start means a limit or a zone that differs from the gateway's.
  A revert does not end the pause: with no `spendStop`, nothing clears it. After a revert, the pause
  stands until the owner resumes nixie, from the client or with `nixie resume` on the host.

**CAUTION:** Never roll nixie's image back while a pause with the cause `spending` stands. The older
release refuses to open the database.

## Rotate the control token

The host file and nixie's secrets file hold the same token, and nixie pauses as `unreachable` while
they differ. Rotate both in one window:

1. Replace the item's value with a new random token. The template reaches `op` through a file
   descriptor, so the token never reaches a command line:

   ```bash
   op item edit model-gateway-control --vault cloud --template <(openssl rand -hex 32 | tr -d '\n' \
     | jq --rawfile value /dev/stdin '(.fields[] | select(.id == "credential") | .value) = $value' \
       <(op item get model-gateway-control --vault cloud --format json)) > /dev/null
   ```

2. Install it on the host, as step 2 there does, and restart the unit:
   `ssh root@geoffcloud systemctl restart model-gateway < /dev/null`.
3. Set nixie's copy, as [change a secret](./nixie.md#change-a-secret) does for the key
   `["settings"]["gateway-control"]`, and merge its PR. nixie stays paused as `unreachable` from
   step 2 until its new pod starts, and the stop clears on its own.

## Failures

| Symptom                                              | Cause                                          | Fix                                                      |
| ---------------------------------------------------- | ---------------------------------------------- | -------------------------------------------------------- |
| the unit is skipped, `ConditionPathExists` unmet     | the token file is missing                      | [set up the control token](#set-up-the-control-token)    |
| the unit restarts, `Failed to start server`          | imp-host has not made podman0 yet              | none: the unit retries every 5 s until the bridge exists |
| `proxy.failed` with a config error                   | the rendered config fails the release's schema | fix `services.model-gateway`, then switch                |
| every request gets a 503, `limit` null in the status | nixie has not set its limits                   | read nixie's log for `spend.limits_unsent`               |
| every request gets a 503, `"lost": true`             | the count fell behind the spend                | [clear the lost mark](#clear-the-lost-mark)              |
| a 403 that names a sandbox the store lacks           | nixie did not register the sandbox             | read nixie's log for the sandbox's registration          |
