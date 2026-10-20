# Previews

These steps set up the preview service on geoffcloud, opt a repository in, and check a preview live.
[Previews](../architecture/workloads/preview.md) explains how the service works. The service's unit
is skipped until its three secret files exist, so a host switch before the setup leaves it stopped
and changes nothing else.

The steps use one helper, which runs imp's CLI in imp-host as impd's root. It sends its standard
input over SSH, so a secret piped into it never reaches the host's journal:

```bash
host_imp() { ssh root@geoffcloud docker exec -i imp-host impz "$@"; }
```

## Set the service up

1. Check that impd holds a GitHub secret named `gh` for the broker, which each preview imp clones
   through:

   ```bash
   host_imp secret ls < /dev/null
   ```

   Expect a line for `gh` of kind `github`. Without it, add a fine-grained token with Contents
   read-only on the opted-in repositories and no other permission:
   `op read op://cloud/<github_item>/credential | host_imp secret add gh --kind github`.

2. Add the model secret that each preview imp and each SDK contract run's imp is granted,
   `preview-model`, from the model credential that nixie uses:

   ```bash
   op read op://cloud/nixie-model-credential/credential | host_imp secret add preview-model \
     --kind custom --hosts api.anthropic.com --header authorization --scheme bearer
   ```

   Expect `host_imp secret ls` to list `preview-model` with the host `api.anthropic.com`. After a
   model credential rotation, run the same command with `--replace`.

3. Mint the service's impd token, which manages only the imps named `pv-*` and grants only `gh` and
   `preview-model`, and write it to the host's encrypted secrets dataset without printing it:

   ```bash
   ssh root@geoffcloud 'install -d -m 0700 /var/lib/tank-cloud/host-secrets/preview && docker exec imp-host impz token new preview --scope manage --imps "pv-*" --grantable gh,preview-model | (umask 077 && cat > /var/lib/tank-cloud/host-secrets/preview/imp-token) && test -s /var/lib/tank-cloud/host-secrets/preview/imp-token && echo ok' < /dev/null
   ```

   Expect `ok`. A token minted before the contract run grants `gh` alone. Point it at both secrets
   with `host_imp token set preview --grantable gh,preview-model < /dev/null`.

4. Make a fine-grained GitHub token for the service, scoped to the opted-in repositories, with
   Contents read, Pull requests read and write, and Commit statuses read and write. The service
   reads `preview/compose.yaml` and each pull request's changed files, writes one comment per pull
   request, and sets the `sdk-contract` status with it. Store it in the 1Password item
   `preview-github-token` of the `cloud` vault, then send it to the host on SSH's standard input:

   ```bash
   op read --no-newline op://cloud/preview-github-token/credential | ssh root@geoffcloud \
     'cd /var/lib/tank-cloud/host-secrets/preview && (umask 077 && cat > github-token.new) && test -s github-token.new \
       && mv github-token.new github-token && echo ok'
   ```

   The host keeps the old file when the read sends nothing, and the command prints `ok` only after
   it replaces the file.

5. Make the webhook secret, store it, and send it the same way:

   ```bash
   op item create --vault cloud --category password --title preview-webhook-secret \
     "password=$(openssl rand -hex 32)" > /dev/null
   op read --no-newline op://cloud/preview-webhook-secret/password | ssh root@geoffcloud \
     'cd /var/lib/tank-cloud/host-secrets/preview && (umask 077 && cat > webhook-secret.new) && test -s webhook-secret.new \
       && mv webhook-secret.new webhook-secret && echo ok'
   ```

6. Switch the host from a clean checkout of `main` that a green `NixOS checks` run covers:
   `bash scripts/switch-geoffcloud.sh`. Then start the unit, which the switch skipped while its
   secrets were missing, and read its first line:

   ```bash
   ssh root@geoffcloud 'systemctl restart preview && sleep 2 && journalctl -u preview -n 5 --no-pager'
   ```

   Expect `previews: links on 100.69.47.33:8417, webhook on 100.69.47.33:8418`.

7. Check the public route, which the Pulumi program declares: `preview-webhook.geoff.cloud` passes
   only the path `/webhook` to the webhook listener. Once the apply has run, an unsigned call gets
   the service's refusal, and any other path gets the tunnel's 404:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://preview-webhook.geoff.cloud/webhook
   curl -s -o /dev/null -w '%{http_code}\n' https://preview-webhook.geoff.cloud/
   ```

   Expect `401`, then `404`.

8. Add a webhook to each opted-in repository, or once to the owner's account for every repository:
   the payload URL `https://preview-webhook.geoff.cloud/webhook`, which the stack exports as
   `previewWebhookURL`, content type `application/json`, the secret from step 5, and the "Pull
   requests" event alone. Expect GitHub's ping delivery to get a 204.

## Opt a repository in

A repository opts in with a `preview/` folder, a webhook, and a place in the host's
`services.preview.repos`, which names each opted-in repository, and in the `gh` token's repository
list. The folder holds one Compose file, whose services start the app, seed it with invented data,
and publish the app's HTTP port on the guest:

```yaml
x-preview:
  port: 8080 # the guest port the app publishes; impd forwards each request there
  health: /healthz # a path that answers 2xx once the app is ready
services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_PASSWORD: preview-only
    healthcheck:
      test: [CMD, pg_isready, -U, postgres]
      interval: 1s
      retries: 30
  seed:
    image: postgres:17-alpine
    depends_on:
      db:
        condition: service_healthy
    environment:
      PGPASSWORD: preview-only
    command: [psql, -h, db, -U, postgres, -f, /seed/invented.sql]
    volumes:
      - ./seed:/seed:ro
  web:
    build: ..
    depends_on:
      seed:
        condition: service_completed_successfully
    ports:
      - '8080:8080'
```

The seed loads data written for the preview, never a copy of production data. Each boot starts the
stack on empty volumes, so the seed runs once per build. A preview of a push builds the new commit's
`preview/compose.yaml`, so a pull request can change its own preview.

## Run the SDK contract suite on a pull request

A repository runs its SDK contract suite on each pull request that changes the Agent SDK's pin once
the host's `services.preview.contractRepos` lists it and the service's webhook reaches it. The suite
runs `NIXIE_SDK_CONTRACT=1 bun test evals/sdk-contract` at the head commit, so the repository needs
that folder and a `bun.lock`. Each run's imp installs Bun's pinned build, so a repository that moves
its package manager to another Bun release needs the pin in the service's contract run moved with
it.

Check a run live once the setup and a host switch are done:

1. Open a pull request in a contract repository that changes the SDK's version in `package.json` or
   `bun.lock`. Expect the head commit's `sdk-contract` status to read
   `Running the SDK contract suite` within a minute, and `host_imp ls` to show one `pv-sdk-<hash>`
   imp.
2. Wait for the run to end, about 5 minutes. Expect the status to turn success or failure with the
   suite's counts, such as `18 pass, 0 fail`, and `host_imp ls` to show no `pv-sdk-` imp.
3. Push a commit that leaves the pin alone. Expect the new head to get no `sdk-contract` status.

A run that waits reads `Waiting for a free preview slot`, and the service tries it again each minute
until a preview sleeps or goes. The journal holds the tail of each run's output:

```bash
ssh root@geoffcloud journalctl -u preview -n 100 --no-pager
```

An error status that reads `The run's imp did not start` ends with impd's refusal: a refused grant
means the token lacks `preview-model` in its grantable list. A run that fails before the suite
reports broke in the install or the fetch, such as a `bun.lock` that `bun install --frozen-lockfile`
refuses.

A journal line that ends `(the token needs statuses=write)` means the service's GitHub token lacks
Commit statuses write, which GitHub needs for every status the service sets. Add that permission to
the token in step 4. The run stays settling until then, and the next retry sets its status.

## Check a preview live

Run these checks from a device on the tailnet, a phone among them, after the setup.

1. Open a pull request in an opted-in repository whose head has `preview/compose.yaml`. Expect one
   comment from the service's token that starts with
   `**Preview:** http://geoffcloud:8417/<owner>/<repo>/<number>`.
2. Open the link on the phone. Expect the page "Preview booting", which reloads, and then a redirect
   to `https://pv-<hash>-<number>.imps.geoff.cloud/` that shows the app with its invented data.
3. Push a commit to the pull request. Expect the comment to name the new commit, and the link to
   boot again on its next open.
4. Put the preview to sleep, then open the link again:

   ```bash
   host_imp sleep pv-<hash>-<number> < /dev/null
   ```

   Expect the app back in seconds with the state it had, and `host_imp ls` to show the imp
   `running`.

5. With one slot, open the link of a second pull request. Expect `host_imp ls` to show the first
   preview `sleeping` once the second one boots.
6. Close the pull request. Expect the comment to start with `**Preview ended.**`, the link to answer
   "Preview ended", and `host_imp ls` to list no imp of that pull request.

## When a preview fails

The link shows the tail of the build output and a retry link. The service's journal holds each phase
change:

```bash
ssh root@geoffcloud journalctl -u preview -n 50 --no-pager
```

A boot that fails on `PRECONDITION_FAILED` ran without the broker: check step 1 and the token's
grantable secret. A boot that times out reached `docker compose up` but never got an answer on the
health path: run
`host_imp exec pv-<hash>-<number> -- docker compose -f /srv/preview/preview/compose.yaml ps` to see
which service stopped.

A boot whose failure says the port did not answer through impd's proxy built and started its stack,
but nothing listens on the imp's own address. The failure quotes the proxy's last answer, such as
`502 Nothing answers in the imp`. Publish the port on every address of the guest (`'8080:8080'`,
never `'127.0.0.1:8080:8080'`), and make the app listen on `0.0.0.0` inside its container.
