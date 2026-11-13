# pepys: first deploy and release bump

Deploy [pepys](../architecture/workloads/pepys.md), the owner's data hub, to the cluster the first
time, and move the cluster to a later pepys release. [Deploy the first time](#deploy-the-first-time)
is for a cluster whose [stack config](./workflows.md#change-stack-config) holds no `pepys` object.
[Bump the pepys release](#bump-the-pepys-release) is for each pepys release after that. Other
runbooks cover the rest of what an operator does by hand:
[telemetry from sessions](./pepys-telemetry.md),
[the API's public route and its clients](./pepys-api.md), and [the backup](./pepys-backup.md).

## Deploy the first time

The Pulumi program deploys pepys only when the stack config holds a `pepys` object: the key
`geoff-cloud:pepys` in `infra/Pulumi.prod.yaml`. Without the object, the pepys code on `main`
changes nothing in prod.

**CAUTION:** These steps add a public route. The `Deploy prod` run of the merge in step 4 holds at
the tunnel route change, and step 5 answers the held run. Get the owner's approval before you answer
it, as [the prod apply job](./prod-apply.md) describes.

1. Read the image's tag and digest in the summary of the newest
   [`pepys image`](../../.github/workflows/pepys-image.yml) run on `main`. The workflow publishes
   `ghcr.io/zgeoff/cloud-pepys:<release>-<commit>`, where `<release>` is the pepys release without
   its `v`, and `<commit>` is the first 12 digits of the commit. A push to a container package that
   ghcr.io does not hold yet creates the package and then fails with `denied`. Rerun the failed job,
   which publishes the tag.
2. In a pull request, add the `pepys` object to `infra/Pulumi.prod.yaml`, with the tag and the
   digest, `<digest>`, from step 1:

   ```yaml
   geoff-cloud:pepys:
     image: ghcr.io/zgeoff/cloud-pepys:<release>-<commit>@sha256:<digest>
     webhookHostname: pepys-webhook.geoff.cloud
     impIdentityAudience: pepys.imp.internal
   ```

3. Run `bun run preview` from the repo root, as [First preview](./development.md#first-preview) sets
   up. Expect the preview to add the `pepys` namespace, its network policies, Secrets, Services and
   workloads. Expect it to add the rule of
   [the shared tunnel](../architecture/network/public-ingress.md#the-shared-tunnel) and the proxied
   record for `pepys-webhook.geoff.cloud`. Expect no other change. The preview adds the backup
   CronJob only when `.env` names
   [the backup variables](./pepys-backup.md#give-the-backup-its-garage-key).
4. Merge the pull request.
5. Once the plan of the held `Deploy prod` run matches the preview, answer the run, as
   [Answer a held run](./prod-apply.md#answer-a-held-run) says.
6. Check that the workloads are up:

   ```bash
   ssh root@geoffcloud k3s kubectl -n pepys rollout status statefulset/pepys-host --timeout=300s
   ```

   Expect `statefulset rolling update complete`. Run the command again for
   `statefulset/pepys-garage`, and expect the same line. Run it for `deployment/pepys-s2` and
   `deployment/pepys-ingest`, and expect `deployment "<name>" successfully rolled out`, where
   `<name>` is the Deployment's name.

7. Check that the public route refuses an unsigned delivery:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://pepys-webhook.geoff.cloud/webhook/github
   ```

   Expect `401`.

## Bump the pepys release

The `cloud-pepys` image holds the pepys host, a binary that the pepys release publishes, beside
ingest, the API and the consumer modules, which the image build compiles from the `@pepys/*`
packages in `deploy/pepys`. [Processes](../architecture/workloads/pepys.md#processes) and
[The image](../architecture/workloads/pepys.md#the-image) explain the host, its consumers and the
fact log. The binary and the packages must come from one release, so a bump changes `PEPYS_RELEASE`
and the package versions in one pull request.
[`collect-pepys-version-mismatches.test.ts`](../../scripts/collect-pepys-version-mismatches.test.ts)
fails when the release and a package version differ.

1. Set `PEPYS_RELEASE` and `PEPYS_HOST_ASSET_SHA256` in
   [`images/pepys/versions.env`](../../images/pepys/versions.env). The checksum is the line of
   `pepys-host-linux-x64` in the release's `SHA256SUMS`, and the image build stops on a checksum of
   another release. The bump pull request that [the release check](./release-check.md) opens on the
   branch `release-check/pepys` sets both lines, and changes only this file.
2. Set each `@pepys/*` version in `deploy/pepys/package.json` to that release, by hand.
3. Check that `@boxxy/pepys`, the boxxy plug-in in `deploy/pepys/package.json`, admits the release.
   The plug-in's own `package.json` gives its range on `@pepys/kit` under `peerDependencies`. When
   the range leaves the release out, set `@boxxy/pepys` to a version whose range admits it.
   `@boxxy/pepys` carries boxxy's own version.
4. Run `bun install` in `deploy/pepys` to write its lock again. Then run
   `bun run check:pepys-deployment` from the repo root. Expect exit 0.
5. Merge the pull request. Its `pepys image` run on `main` publishes the image of the release, and
   the run summary gives the image's tag and digest.
6. Open a second pull request that sets `image` in the `geoff-cloud:pepys` object of
   `infra/Pulumi.prod.yaml` to that tag and digest. Merge it. The `Deploy prod` workflow applies it
   once CI passes on `main`.
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
   consumer's rows again from the fact log. When the fact log refuses the connection at start, the
   host logs `pepys: up <consumer> retries in <n> ms after a store error` and tries again, up to 10
   times, so the lines above follow the retry lines. When the host exits after the last retry, the
   pod starts the host again. When the starts keep failing, check `deployment/pepys-s2`.
