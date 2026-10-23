# Previews

These steps set up the preview service on geoffcloud, opt a repository in, and check a preview live.
[Previews](../architecture/workloads/preview.md) explains how the service works. The service's unit
is skipped until its four secret files exist, so a host switch before the setup leaves it stopped
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

4. Make the webhook secret, store it in the 1Password item `preview-webhook-secret` of the `cloud`
   vault, and send it to the host on SSH's standard input. Skip the `op item create` line when the
   item exists:

   ```bash
   op item create --vault cloud --category password --title preview-webhook-secret \
     "password=$(openssl rand -hex 32)" > /dev/null
   op read --no-newline op://cloud/preview-webhook-secret/password | ssh root@geoffcloud \
     'cd /var/lib/tank-cloud/host-secrets/preview && (umask 077 && cat > webhook-secret.new) && test -s webhook-secret.new \
       && mv webhook-secret.new webhook-secret && echo ok'
   ```

   The host keeps the old file when the read sends nothing, and the command prints `ok` only after
   it replaces the file.

5. Create the preview GitHub App on the owner's account, under Settings, Developer settings, GitHub
   Apps, New GitHub App:
   - Webhook: active, with the URL `https://preview-webhook.geoff.cloud/webhook`, which the stack
     exports as `previewWebhookURL`, and the secret from step 4. Copy the secret from the 1Password
     item into the form.
   - Repository permissions: Contents read-only, Pull requests read and write, and Commit statuses
     read and write. GitHub adds Metadata read-only itself. The service reads `preview/compose.yaml`
     and each pull request's changed files, writes one comment per pull request, and sets the
     `sdk-contract` status.
   - Subscribe to events: Pull request, and no other event.
   - Where can this GitHub App be installed: Only on this account.

   Create the App, then copy the client ID from its General page.

6. Generate the App's private key on the same page. GitHub downloads it as a `.pem` file. Store the
   client ID and the key in the `cloud` vault, delete the downloaded file, and send both to the
   host:

   ```bash
   op item create --vault cloud --category "API Credential" --title preview-github-app \
     'client-id[text]=<client_id>' > /dev/null
   op document create <downloaded_pem> --vault cloud --title preview-github-app-key > /dev/null \
     && rm <downloaded_pem>
   op read --no-newline op://cloud/preview-github-app/client-id | ssh root@geoffcloud \
     'cd /var/lib/tank-cloud/host-secrets/preview && (umask 077 && cat > github-app-client-id.new) \
       && test -s github-app-client-id.new && mv github-app-client-id.new github-app-client-id && echo ok'
   op document get preview-github-app-key --vault cloud | ssh root@geoffcloud \
     'cd /var/lib/tank-cloud/host-secrets/preview && (umask 077 && cat > github-app-key.new) \
       && test -s github-app-key.new && mv github-app-key.new github-app-key && echo ok'
   ```

   Expect `ok` twice. The service refuses to start on a key file that is not a PEM private key, and
   its journal says `the credential github-app-key is not a PEM private key`.

7. Switch the host from a clean checkout of `main` that a green `NixOS checks` run covers:
   `bash scripts/switch-geoffcloud.sh`. Then start the unit, which the switch skipped while its
   secrets were missing, and read its first line:

   ```bash
   ssh root@geoffcloud 'systemctl restart preview && sleep 2 && journalctl -u preview -n 5 --no-pager'
   ```

   Expect `previews: links on 100.69.47.33:8417, webhook on 100.69.47.33:8418`.

8. Check the public route, which the Pulumi program declares: `preview-webhook.geoff.cloud` passes
   only the path `/webhook` to the webhook listener. Once the apply has run, an unsigned call gets
   the service's refusal, and any other path gets the tunnel's 404:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://preview-webhook.geoff.cloud/webhook
   curl -s -o /dev/null -w '%{http_code}\n' https://preview-webhook.geoff.cloud/
   ```

   Expect `401`, then `404`.

9. Open the App's Advanced page and redeliver its ping from Recent Deliveries. Expect the redelivery
   to get a 204.

## Cap each preview's model spend

The spend cap puts a counting proxy on each preview's model route, as
[the spend cap](../architecture/workloads/preview.md#the-spend-cap) describes. It needs a nixie
release that ships `counting-proxy-linux-x64`, which the host pins by its sha256.

1. Add the counted model secret, whose upstream is the service's model route listener:

   ```bash
   op read op://cloud/nixie-model-credential/credential | host_imp secret add preview-model-counted \
     --kind custom --hosts api.anthropic.com --header authorization --scheme bearer \
     --upstream http://172.17.0.1:18082
   ```

   Expect `host_imp secret ls` to list `preview-model-counted`. The SDK contract run keeps
   `preview-model`, because its suite runs no preview code.

2. Let the service's token grant it:
   `host_imp token set preview --grantable gh,preview-model,preview-model-counted < /dev/null`.

3. In the host config, set `services.preview.impModelSecret` to `preview-model-counted` and turn on
   `services.preview.spendCap` with the pinned package, the model, its prices and the limit. Switch
   the host as step 6 of [Set the service up](#set-the-service-up) does, and expect the unit's log
   to hold `previews: model routes on 172.17.0.1:18082`, with the limit after it.

4. Remove each preview imp that booted before the switch:
   `host_imp rm pv-<hash>-<number> < /dev/null` for each `pv-` name that
   `host_imp ls --json < /dev/null` lists. A link open only wakes a ready imp, so its stack keeps
   running without the route until it boots again. Each boot removes every grant but the service's
   own, so the next one leaves the imp with the counted grant alone.

5. Open a preview of a repository whose stack takes the route, and ask its app for a model reply.
   Expect `journalctl -u preview` to hold the proxy's `proxy.started` line under the imp's name.

A preview past its limit gets a 403 from its proxy on every later model call until its pull request
closes. Raise `limitDollars` and switch the host to let it go on; the count keeps what it spent.

## Opt a repository in

A repository opts in with a `preview/` folder and an install of the preview GitHub App. The host's
`services.preview.repos` lists every repository of the owner, and the App installs only on the
owner's account, so the install is the only switch. Install the App from its public page, under
Install App, and add the repository to the installation's repository list. A private repository
needs a place in the `gh` token's repository list too, so that each preview imp can clone it. The
folder holds one Compose file, whose services start the app, seed it with invented data, and publish
the app's HTTP port on the guest:

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
the host's `services.preview.contractRepos` lists it and the preview GitHub App is installed on it.
The suite runs `NIXIE_SDK_CONTRACT=1 bun test evals/sdk-contract` at the head commit, so the
repository needs that folder and a `bun.lock`. Each run's imp installs Bun's pinned build, so a
repository that moves its package manager to another Bun release needs the pin in the service's
contract run moved with it.

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

A journal line that ends `(the App needs statuses=write)` means the preview GitHub App lacks Commit
statuses write, which GitHub needs for every status the service sets. Add that permission on the
App's Permissions page, as in step 5, then accept the new permission on the installation's page. A
run whose final status GitHub refuses this way ends at once, and the journal line that ends it holds
the result, `the status was not posted` and the refusal. The commit's `sdk-contract` status stays as
it was.

## Check a preview live

Run these checks from a device on the tailnet, a phone among them, after the setup.

1. Open a pull request in an opted-in repository whose head has `preview/compose.yaml`. Expect one
   comment from the App's bot, `<app_slug>[bot]`, that starts with
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

## Retire the fine-grained token and the repository webhooks

A host that ran the service before the preview GitHub App holds a fine-grained token,
`preview-github-token`, and each opted-in repository has a webhook to the same URL as the App's. Run
these steps once the switch to the App is done and the live check passes on one repository:

1. Install the App on every repository that has a webhook to
   `https://preview-webhook.geoff.cloud/webhook`. Until you remove the webhook, the service gets
   each event twice and applies it twice, which posts nothing new.
2. Remove each repository's webhook. List them, then remove the one whose `config.url` is the
   preview URL:

   ```bash
   gh api repos/<owner>/<repo>/hooks --jq '.[] | [.id, .config.url] | @tsv'
   gh api -X DELETE repos/<owner>/<repo>/hooks/<hook_id>
   ```

   Expect the second command to print nothing and exit 0.

3. Delete the token in GitHub, under Settings, Developer settings, Personal access tokens,
   Fine-grained tokens. Then delete its 1Password item and its host file:

   ```bash
   op item delete preview-github-token --vault cloud
   ssh root@geoffcloud 'rm -f /var/lib/tank-cloud/host-secrets/preview/github-token && echo ok' < /dev/null
   ```

   Expect `ok`.

A pull request that was open before the switch keeps the token's comment, and the App's bot posts a
comment of its own on the next event, because GitHub lets the App edit only its own comments. Delete
the old comment by hand.

## When a preview fails

The link shows the tail of the build output and a retry link. The service's journal holds each phase
change:

```bash
ssh root@geoffcloud journalctl -u preview -n 50 --no-pager
```

A journal line that ends `/installation: HTTP 404: Not Found` names a repository that the App is not
installed on, such as one removed from the installation's repository list while a preview of it ran.
Add the repository to the installation again before you close its pull requests. GitHub sends no
delivery for a repository the App is not installed on, so a close without the installation never
reaches the service, and the preview's record and imp stay. To retire such a repository, restore the
installation, close or merge its open pull requests, and only then remove the repository from the
installation.

A boot that fails on `PRECONDITION_FAILED` ran without the broker: check step 1 and the token's
grantable secret. A boot that times out reached `docker compose up` but never got an answer on the
health path: run
`host_imp exec pv-<hash>-<number> -- docker compose -f /srv/preview/preview/compose.yaml ps` to see
which service stopped.

A boot whose failure says the port did not answer through impd's proxy built and started its stack,
but nothing listens on the imp's own address. The failure quotes the proxy's last answer, such as
`502 Nothing answers in the imp`. Publish the port on every address of the guest (`'8080:8080'`,
never `'127.0.0.1:8080:8080'`), and make the app listen on `0.0.0.0` inside its container.
