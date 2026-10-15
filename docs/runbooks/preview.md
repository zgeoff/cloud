# Previews

These steps set up the preview service on geoffcloud, opt a repository in, and check a preview live.
[Previews](../architecture/workloads/preview.md) explains how the service works. The service's unit
is skipped until its three secret files exist, so a host switch before the setup leaves it stopped
and changes nothing else.

The steps use one helper, which runs imp's CLI in imp-host as impd's root. It sends its standard
input over SSH, so a secret piped into it never reaches the host's journal:

```bash
host_imp() { ssh root@geoffcloud docker exec -i imp-host imp "$@"; }
```

## Set the service up

1. Check that impd holds a GitHub secret named `gh` for the broker, which each preview imp clones
   through:

   ```bash
   host_imp secret ls < /dev/null
   ```

   Expect a line for `gh` of kind `github`. Without it, add a token that reads the opted-in
   repositories:
   `op read op://cloud/<github_item>/credential | host_imp secret add gh --kind github`.

2. Mint the service's impd token, which manages only the imps named `pv-*` and grants only `gh`, and
   write it to the host's encrypted secrets dataset without printing it:

   ```bash
   ssh root@geoffcloud 'install -d -m 0700 /var/lib/tank-cloud/host-secrets/preview && docker exec imp-host imp token new preview --scope manage --imps "pv-*" --grantable gh | (umask 077 && cat > /var/lib/tank-cloud/host-secrets/preview/imp-token) && test -s /var/lib/tank-cloud/host-secrets/preview/imp-token && echo ok' < /dev/null
   ```

   Expect `ok`.

3. Make a fine-grained GitHub token for the service, scoped to the opted-in repositories, with
   Contents read and Pull requests read and write. The service reads `preview/compose.yaml` and
   writes one comment per pull request with it. Store it in the 1Password item
   `preview-github-token` of the `cloud` vault, then send it to the host on SSH's standard input:

   ```bash
   op read --no-newline op://cloud/preview-github-token/credential | ssh root@geoffcloud \
     '(umask 077 && cat > /var/lib/tank-cloud/host-secrets/preview/github-token) && echo ok'
   ```

4. Make the webhook secret, store it, and send it the same way:

   ```bash
   op item create --vault cloud --category password --title preview-webhook-secret \
     "password=$(openssl rand -hex 32)" > /dev/null
   op read --no-newline op://cloud/preview-webhook-secret/password | ssh root@geoffcloud \
     '(umask 077 && cat > /var/lib/tank-cloud/host-secrets/preview/webhook-secret) && echo ok'
   ```

5. Switch the host from a clean checkout of `main` that a green `NixOS checks` run covers:
   `bash scripts/switch-geoffcloud.sh`. Then start the unit, which the switch skipped while its
   secrets were missing, and read its first line:

   ```bash
   ssh root@geoffcloud 'systemctl restart preview && sleep 2 && journalctl -u preview -n 5 --no-pager'
   ```

   Expect `previews: links on 100.69.47.33:8417, webhook on 100.69.47.33:8418`.

6. Add the public route in a reviewed Pulumi change: a tunnel hostname whose origin is
   `http://100.69.47.33:8418`, with its `tunnel-hostname` entry in the exposure registry and its
   reason in the pull request. Only the path `/webhook` needs to pass.

7. Add a webhook to each opted-in repository, or once to the owner's account for every repository:
   the payload URL `https://<webhook_hostname>/webhook`, content type `application/json`, the secret
   from step 4, and the "Pull requests" event alone. Expect GitHub's ping delivery to get a 204.

## Opt a repository in

A repository opts in with a `preview/` folder, a webhook, and a place in the host's
`services.preview.repos`, which lists `zgeoff/*`. The folder holds one Compose file, whose services
start the app, seed it with invented data, and publish the app's HTTP port on the guest:

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
