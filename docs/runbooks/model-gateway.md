# The model gateway

nixie's model gateway runs on the host as the `model-gateway` unit, from the release binary that
[`nixos/packages/model-gateway.nix`](../../nixos/packages/model-gateway.nix) pins. Every model
request of production nixie passes it: imp-host's broker sends each request of a nixie sandbox to
the gateway's model listener, the gateway counts the reply's dollars in its route's day and month,
which reset at midnight in nixie's time zone, and it refuses a route's requests once either count
reaches that route's limit. Each route's limits sit in the gateway's own config, and no limit spans
routes. nixie reads the gateway's status on the control listener, and can raise a route's day up to
its day cap. The gateway pin and nixie's image come from the same nixie release: nixie refuses the
status of an older gateway, and pauses.
[nixie's model gateway](https://github.com/zgeoff/nixie/blob/main/docs/architecture/policy/model-gateway.md)
describes the gateway, and
[`nixos/modules/model-gateway.nix`](../../nixos/modules/model-gateway.nix) describes the unit, its
listeners and their firewall paths.

**CAUTION:** The gateway fails closed. While it is stopped, while its store is unreadable, and while
the lost mark stands, every model request of nixie fails. Never stop the unit while nixie works,
outside a host switch.

## What holds what

| Where                                                                        | Holds                                                                        |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| vault `cloud`, item `model-gateway-control`, field `credential`              | the control token, 64 hex characters                                         |
| `/var/lib/tank-cloud/host-secrets/model-gateway/control-token`               | the same token on the host, mode 0400 root, which the unit loads             |
| `deploy/nixie/secrets.sops.yaml`, key `["settings"]["gateway-control"]`      | nixie's copy of the control token, which nixie sends to the control relay    |
| `/var/lib/model-gateway/store.json`                                          | each route's day and month count, each sandbox's count, the lost mark        |
| `/var/lib/model-gateway/override.json`                                       | a route's day limit past its cap, written by `model-gateway raise`           |
| `services.model-gateway` in `nixos/hosts/geoffcloud/configuration.nix`       | the zone and one priced, limited route per nixie model profile               |
| vault `cloud`, item `model-gateway-gpt-6-luna-route-key`, field `credential` | the route key of the plan route `gpt-6-luna`, 64 hex characters              |
| `/var/lib/tank-cloud/host-secrets/model-gateway/gpt-6-luna-route-key`        | the same key on the host, mode 0400 root, which the unit loads               |
| `/var/lib/model-gateway/chatgpt-login-gpt-6-luna.json`                       | the ChatGPT plan login of `gpt-6-luna`, mode 0600, which the gateway rotates |

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

Expect JSON with the zone `Australia/Sydney`, `"lost": false`, and under `routes` one entry per
route, whose `day` and `month` each hold `start`, `resetsAt`, `dollars`, `limit`, `cap` and
`tripped`. Expect `tripped` false on each period, and each `limit` equal to the route's limit in the
host config. The gateway refuses every request on a route that has no limits with a 503.

Check the listeners with `ssh root@geoffcloud 'ss -ltn' < /dev/null`. Expect `10.88.0.1:8789`, the
model listener, `127.0.0.1:8790`, the control listener, and the relay's socket on the host's tailnet
address at port 8791.

## Raise a route's day past its cap

The control listener refuses a raise above a route's day cap. To let nixie spend past it on one
route for the current day, write the override as the unit's user, so the gateway can read the file:

```bash
ssh root@geoffcloud 'runuser -u model-gateway -- model-gateway raise --config "$(systemctl show -P ExecStart model-gateway | grep -o "/nix/store/[^ ]*model-gateway.yaml")" --route <route_id> --dollars <dollars>' < /dev/null
```

`<route_id>` is the route's key under `routes` in the host config, and `<dollars>` is the day's new
limit. Expect a JSON line with the event `override.written`. The gateway reads the override before
each request and ignores it once its day ends. A month limit has no override: change the route's
`limits` in the host config and switch the host, which also raises a limit for good.

## Clear the lost mark

The gateway writes `"lost": true` into the store when its count fell behind the spend, such as after
a reply that it could not count. While the mark stands, it refuses every request with a 503, across
restarts.

**CAUTION:** The store then holds less than the model API billed. Read `journalctl -u model-gateway`
for the cause, and check the provider's usage page, before you clear the mark.

1. Stop the unit, so no reply writes the store during the edit:
   `ssh root@geoffcloud systemctl stop model-gateway < /dev/null`.
2. Remove the field, keeping the file's owner and mode. The host has no `jq` of its own, so the
   command runs it through `nix run`. The gateway writes the store as mode 0644 inside its 0700
   state directory:

   ```bash
   ssh root@geoffcloud 'cd /var/lib/model-gateway && nix run nixpkgs#jq -- -c "del(.lost)" store.json > store.json.new && chown model-gateway:model-gateway store.json.new && chmod 0644 store.json.new && mv store.json.new store.json' < /dev/null
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

1. Set the helpers and `model_secrets` and `secrets`, as
   [nixie's runbook](./nixie.md#add-nixies-model-secrets-to-impd) step 1 does.
2. Write the rebind as a function, to run at the right moment:

   ```bash
   rebind_model_secrets() { # $1: the upstream, or empty for none
     printf '%s\n' "$model_secrets" | while read -r secret host item; do
       op read "op://cloud/$item/credential" | tr -d '\n' | host_imp secret add "$secret" \
         --kind static --hosts "$host" --header authorization --scheme bearer \
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
   - `host_imp secret ls < /dev/null | grep '^nixie-model-'` shows each secret with its host, then
     `-> http://10.88.0.1:8789`;
   - [the status](#read-the-status) shows each route's limits, and `tripped` false on each period;
   - nixie's log holds no `spend.gateway_unanswered` after its start;
   - the `dollars` of a route that nixie uses rises as nixie works.

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

## Add a model profile

The gateway sends a request only on a route whose ID equals the profile's ID, and prices it with the
route's table. A profile with no route gets a 404 on every call.

1. In one PR, add the profile to `deploy/nixie/config.yaml` and a route to `services.model-gateway`,
   with the same ID, model and prices. A model outside Claude goes through OpenRouter: its base URL
   is `https://openrouter.ai`, with no path, and its route's upstream is
   `https://openrouter.ai/api`. Pin it to one provider endpoint: the profile's `provider_pin` and
   the route's `providerPin` name the same endpoint tag, such as `novita/fp8`, and the prices are
   that endpoint's own.
2. Before the merge, add the profile's model secret and set nixie's token, as
   [nixie's runbook](./nixie.md#add-nixies-model-secrets-to-impd) describes.
3. After the merge, switch the host with `bun run ops:switch-host`, so the gateway has the route,
   then dispatch the held `Deploy prod` run for the config. The new config restarts the unit, and a
   reply still open past its stop wait sets the lost mark, so switch while no task works.

**CAUTION:** A successful reply whose usage the gateway cannot read sets the lost mark, which stops
every model call of nixie. Before you add a model from a new provider, send it one plain and one
streamed request through a local gateway on the release binary, and check that the store's count
rose and holds no `lost`.

## Add the ChatGPT plan route

The route `gpt-6-luna` runs nixie's Codex tasks on the owner's ChatGPT plan. The gateway holds the
plan login, refreshes it and sets its access token on each request, so neither nixie nor a sandbox
holds a plan token.
[nixie's plan login runbook](https://github.com/zgeoff/nixie/blob/main/docs/runbooks/chatgpt-plan-login.md)
explains the parts. A route key ties the two halves: the unit loads it as a credential, and impd's
model secret for the profile holds the same key, so the broker sends it on each plan request. The
gateway refuses a plan request with any other key.

**CAUTION:** The unit needs every route key file to start. A switch that adds a plan route before
its key file exists stops the gateway, and with it every model call of nixie. Do steps 1 to 4 before
the switch.

1. Create the item from a random key, which never reaches a command line or the screen:

   ```bash
   openssl rand -hex 32 | jq -R '{title: "model-gateway-gpt-6-luna-route-key", category: "API_CREDENTIAL",
     fields: [{id: "credential", label: "credential", type: "CONCEALED", value: .}]}' \
     | op item create --vault cloud - > /dev/null
   ```

2. Install the key on the host, on SSH's standard input:

   ```bash
   op read op://cloud/model-gateway-gpt-6-luna-route-key/credential | tr -d '\n' | ssh root@geoffcloud \
     'install -d -m 0700 /var/lib/tank-cloud/host-secrets/model-gateway && (umask 377 && cat > /var/lib/tank-cloud/host-secrets/model-gateway/gpt-6-luna-route-key) && test -s /var/lib/tank-cloud/host-secrets/model-gateway/gpt-6-luna-route-key && echo ok'
   ```

   Expect `ok`. Compare the first 8 hex of each copy's SHA-256, as step 3 of
   [Set up the control token](#set-up-the-control-token) does for the token.

3. Add the profile's model secret to impd with the same key. Set the helpers and `model_secrets` and
   `secrets` first, as [nixie's runbook](./nixie.md#add-nixies-model-secrets-to-impd) step 1 does,
   then:

   ```bash
   op read op://cloud/model-gateway-gpt-6-luna-route-key/credential | tr -d '\n' \
     | host_imp secret add nixie-model-ec71464646636f257fb --kind static --hosts chatgpt.com \
       --header authorization --scheme bearer --upstream http://10.88.0.1:8789
   ```

   Expect a table row for the name. nixie derives the name from the profile `gpt-6-luna`, the header
   `bearer` and the host `chatgpt.com`.

4. Point nixie's token at the list that holds the new name. `--grantable` takes the whole list, and
   a secret left out loses its grants on nixie's imps, so check the list first:

   ```bash
   (
     set -euo pipefail
     held="$(host_imp secret ls --json < /dev/null \
       | jq -r '.[] | select(.name | startswith("nixie-model-")) | .name' | sort)"
     differ="$(comm -3 <(printf '%s\n' "$secret_names" | sort) <(printf '%s\n' "$held"))"
     if [ -n "$differ" ]; then
       printf 'the lists differ, so nothing changed:\n%s\n' "$differ" >&2
       exit 1
     fi
     host_imp token set nixie --grantable "$secrets" < /dev/null
   )
   ```

   Expect the token's row. When the listing fails, or the lists differ, the block stops before
   `token set` and changes nothing: add the missing secret, or the missing case in the script, and
   run it again.

5. Merge the PR that adds the route and the profile, then switch the host and dispatch the held
   `Deploy prod` run, as step 3 of [Add a model profile](#add-a-model-profile) does.

6. Read the login's status on the control listener:

   ```bash
   ssh root@geoffcloud bash -s <<'EOF'
   printf 'Authorization: Bearer %s\n' "$(cat /var/lib/tank-cloud/host-secrets/model-gateway/control-token)" \
     | curl -sS -H @- http://127.0.0.1:8790/chatgpt-logins
   EOF
   ```

   Expect `gpt-6-luna` with `"status": "active"` and the plan type. `needs_login` means the route
   has no login file, or OpenAI refused its refresh: sign the route in, as nixie's runbook's "Sign
   the route in" does, with the config path from `systemctl show -P ExecStart model-gateway` and the
   command run as `runuser -u model-gateway --`.

## Failures

| Symptom                                                      | Cause                                          | Fix                                                                      |
| ------------------------------------------------------------ | ---------------------------------------------- | ------------------------------------------------------------------------ |
| the unit is skipped, `ConditionPathExists` unmet             | the token file is missing                      | [set up the control token](#set-up-the-control-token)                    |
| the unit restarts, `Failed to start server`                  | imp-host has not made podman0 yet              | none: the unit retries every 5 s until the bridge exists                 |
| `proxy.failed` with a config error                           | the rendered config fails the release's schema | fix `services.model-gateway`, then switch                                |
| every request on one route gets a 503                        | the route has no `limits` in the host config   | give the route `limits` in `services.model-gateway`, then switch         |
| nixie paused, `the gateway sent a reply that is not its own` | the gateway pin is an older release than nixie | pin the gateway to nixie's release, then switch                          |
| every request gets a 503, `"lost": true`                     | the count fell behind the spend                | [clear the lost mark](#clear-the-lost-mark)                              |
| a 403 that names a sandbox the store lacks                   | nixie did not register the sandbox             | read nixie's log for the sandbox's registration                          |
| the unit fails, `Failed to set up credentials`               | a plan route's key file is missing             | install it, as [the plan route](#add-the-chatgpt-plan-route) step 2 does |
