# pepys: deploy and release

Deploy [pepys](../architecture/workloads/pepys.md), the owner's data hub, to the cluster the first
time, and move it to a later pepys release. Use [Deploy the first time](#deploy-the-first-time)
once, while the stack config holds no `pepys` object. Use
[Bump the pepys release](#bump-the-pepys-release) for each pepys release after it. Three other
runbooks cover the rest of what an operator does by hand:
[telemetry from sessions](./pepys-telemetry.md),
[the API's public route and its clients](./pepys-api.md), and [the backup](./pepys-backup.md).

## Deploy the first time

**CAUTION:** The first apply adds a public route. Its `Deploy prod` run holds on the tunnel route
change until the owner approves it, as [the prod apply job](./prod-apply.md) describes.

The Pulumi program deploys pepys only when [stack config](./workflows.md#change-stack-config)
`pepys` exists, so the service merges first and changes nothing in prod.

1. Merge the service. The [`pepys image` workflow](../../.github/workflows/pepys-image.yml)
   publishes `ghcr.io/zgeoff/cloud-pepys:<release>-<commit>` from `main`, and its run summary gives
   the digest. `<release>` is the pepys release without its `v`, and `<commit>` is the first 12
   digits of the commit. When the package does not exist yet, the first push creates it and then
   fails with `denied`: rerun the failed job, which publishes the tag.
2. In a pull request, add the `pepys` object to `infra/Pulumi.prod.yaml`. `<digest>` is the digest
   from the run summary:

   ```yaml
   geoff-cloud:pepys:
     image: ghcr.io/zgeoff/cloud-pepys:<release>-<commit>@sha256:<digest>
     webhookHostname: pepys-webhook.geoff.cloud
     impIdentityAudience: pepys.imp.internal
   ```

3. Run `bun run preview`. Expect it to add the `pepys` namespace, its network policies, Secrets,
   Services and workloads, the shared tunnel's rule and the proxied record for
   `pepys-webhook.geoff.cloud`, and to change nothing else. The preview adds the backup CronJob only
   when `.env` holds [the backup variables](./pepys-backup.md).
4. Merge the pull request.
5. Approve the held `Deploy prod` run once its plan matches the preview, as
   [Answer a held run](./prod-apply.md#answer-a-held-run) says.
6. Check that the workloads are up:

   ```bash
   ssh root@geoffcloud k3s kubectl -n pepys rollout status statefulset/pepys-host --timeout=300s
   ```

   Expect `statefulset rolling update complete`. Check `statefulset/pepys-garage`,
   `deployment/pepys-s2` and `deployment/pepys-ingest` the same way.

7. Check that the public route refuses an unsigned delivery:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://pepys-webhook.geoff.cloud/webhook/github
   ```

   Expect `401`.

## Bump the pepys release

The binaries and the modules must come from one release, so a bump changes the pin and the packages
in one pull request.
[`collect-pepys-version-mismatches.test.ts`](../../scripts/collect-pepys-version-mismatches.test.ts)
fails when the release and a package version differ.

1. Set `PEPYS_RELEASE` and `PEPYS_HOST_ASSET_SHA256` in
   [`images/pepys/versions.env`](../../images/pepys/versions.env). The checksum is the line of
   `pepys-host-linux-x64` in the release's `SHA256SUMS`, and the image build stops on a checksum of
   another release. The bump pull request of [the release check](./release-check.md) sets both
   lines, and changes only this file.
2. Set each `@pepys/*` version in `deploy/pepys/package.json` to that release, by hand.
3. Check that the peer range of `@boxxy/pepys` on `@pepys/kit` admits the release. When it does not,
   pin an `@boxxy/pepys` whose range does. `@boxxy/pepys` carries boxxy's own version.
4. Run `bun install` in `deploy/pepys` to write its lock again. Then run
   `bun run check:pepys-deployment` from the repo root. Expect exit 0.
5. Merge the pull request. Its `pepys image` run on `main` publishes the image of the release, and
   the run summary gives the image's tag and digest.
6. Pin that image in `infra/Pulumi.prod.yaml`, in a second pull request, and merge it.
7. After the `Deploy prod` run of the pin, read the pepys host's start log. The host starts with
   `run --up`, so it deploys each consumer's module of the release before it applies new facts:

   ```bash
   ssh root@geoffcloud k3s kubectl -n pepys logs pepys-host-0 -c host
   ```

   Expect one line for each consumer, with the hash of its module:

   ```text
   github_pull_request b8843619…: swapped
   github_release 37fd0758…: no swap, the version is current
   ```

   The host logs `swapped` for a consumer whose module changed in the release: it built that
   consumer's rows again from the fact log. When a start fails with
   `up <consumer> failed: s2: connection refused`, the pod starts the host again, and the lines
   above come from the first start that succeeds. When the starts keep failing, check
   `deployment/pepys-s2`.
