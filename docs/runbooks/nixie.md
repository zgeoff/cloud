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

2. Add the model secret under the name nixie derives,
   `model-<profile>-<first 16 hex of the SHA-256 of "bearer", the API host and the credential>`:

   ```bash
   secret=model-opus-$(op read op://cloud/nixie-model-credential/credential \
     | { IFS= read -r c; printf 'bearer\napi.anthropic.com\n%s' "$c"; } | sha256sum | cut -c1-16)
   op read op://cloud/nixie-model-credential/credential | host_imp secret add "$secret" \
     --kind custom --hosts api.anthropic.com --header authorization --scheme bearer
   ```

   Expect `host_imp secret ls` to list the name with the host `api.anthropic.com`.

## Mint nixie's impd token

The token manages only nixie's imps and grants only the model secret. Mint it straight into the
secrets file, so its value never prints:

```bash
host_imp token new nixie --scope manage --imps 'nixie-*' --grantable "$secret" < /dev/null \
  | tr -d '\n' | jq -Rs . | sops_nixie set --value-stdin secrets.sops.yaml '["impd_token"]'
```

impd shows the secret only once, so if the sops step fails, remove the token with
`host_imp token rm nixie < /dev/null` and mint it again.

After a model credential rotation, point the token at the new secret instead with
`host_imp token set nixie --grantable "$secret"`, and remove the old secret once nixie runs on the
new one.

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

## Enrol a device

nixie signs a device in with a one-time code:

```bash
ssh root@geoffcloud k3s kubectl -n nixie exec nixie-0 -c nixie -- bun /app/main.js enrol-code
```

Open `https://nixie.geoff.cloud` on the device and enter the code before it expires.

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
