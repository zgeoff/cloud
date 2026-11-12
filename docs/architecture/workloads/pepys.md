# pepys

pepys is the owner's personal data hub. Its ingest takes signed deliveries and stores them as facts
in a log, its host runs the deployment's consumers over that log into a store, and its API serves
the store. The cluster runs it in the namespace `pepys` once stack config `pepys` is set. Only the
GitHub webhook route is public. Everything else stays inside the cluster.

## Processes

| Workload       | Kind                   | Image                         | Reads                                   |
| -------------- | ---------------------- | ----------------------------- | --------------------------------------- |
| `pepys-garage` | StatefulSet, 1 replica | Garage, by its publisher      | its config from a ConfigMap             |
| `pepys-s2`     | Deployment, `Recreate` | s2, by its publisher          | the `facts` bucket in Garage            |
| `pepys-ingest` | Deployment             | `cloud-pepys`                 | s2-lite, the route secrets              |
| `pepys-host`   | StatefulSet, 1 replica | `cloud-pepys`, two containers | s2-lite; the API reads the host's store |
| `pepys-backup` | CronJob, 05:00 nightly | rclone, by its publisher      | every bucket in Garage                  |

[`pepys-workloads.ts`](../../../infra/shared/pepys-workloads.ts) holds each name, port and
in-cluster URL. [`pepys-images.ts`](../../../infra/shared/pepys-images.ts) pins the three images
from their publishers, the same Garage and s2 builds that the pepys repo's test stack runs.

Garage starts with `--single-node`, which assigns its layout on the first start, and with
`--default-bucket`, which creates the `facts` bucket with s2-lite's key on it. Garage's secrets and
that key reach it through the environment, so [`garage.toml`](../../../deploy/pepys/garage.toml)
holds no secret. Garage, the host's store and their volumes use `local-path-retain`, so a deleted
claim keeps its data.

The host runs `pepys-host run --up`, which deploys each consumer that `/modules/consumers.json`
lists before it tails the streams. The API runs in the same pod and reads the store files that the
host writes. Ingest and the API listen on `0.0.0.0`, because each listens on 127.0.0.1 unless told
otherwise, and no Service reaches a loopback listener.

## The image

`cloud-pepys` holds three binaries and the consumer modules. The deployment that it builds lives in
`deploy/pepys`: `deployment.ts`, the entry files `ingest.ts` and `api.ts`, and a `package.json` with
the `@pepys/*` packages. That folder installs on its own, apart from the repo's workspaces, with its
own `bunfig.toml` and lock, so the root type check and lint leave its TypeScript out, and
`bun run check:pepys-deployment` installs and type-checks it.

[`write-pepys-image-context.sh`](../../../scripts/write-pepys-image-context.sh) writes the build
context, after `bun install --frozen-lockfile` in `deploy/pepys`:

1. It checks `ingest-routes.json` against the deployment, as [Routes](#routes) says, and stops on a
   difference before it downloads or builds anything.
2. It downloads the host binary of the release that
   [`images/pepys/versions.env`](../../../images/pepys/versions.env) pins, and checks the binary
   against the release's `SHA256SUMS` and against the pin.
3. It runs `pepys build` on the deployment file for the modules.
4. It compiles the two entry files with
   [`compile-entries.ts`](../../../deploy/pepys/compile-entries.ts).

The `@pepys/*` packages must carry the version that `PEPYS_RELEASE` names, so that the binaries and
the modules come from one release. A release bump changes `PEPYS_RELEASE` and each `@pepys/*`
version in `deploy/pepys/package.json` in one pull request, with the lock of `deploy/pepys` written
again. The shared release tooling changes only `images/pepys/versions.env`, so change the package
versions and the lock by hand in its pull request.
[`collect-pepys-version-mismatches.test.ts`](../../../scripts/collect-pepys-version-mismatches.test.ts)
fails when the release and a package version differ.

The compile embeds Turso's native addon in the API. Turso's loader reaches the addon through
`createRequire`, which `bun build --compile` does not follow, so the compile script drops that call,
and fails when a Turso release no longer holds it. At start the API writes the addon to `/tmp` and
loads it from there, so the API's `/tmp` must allow exec. An emptyDir does; Docker's `--tmpfs` does
not, unless it is mounted with `exec`.

`bun run test:pepys-image` builds the image from a stand-in context and runs its suite: each program
starts as nonroot from a 0555 file, and that user reads the modules, which root owns. CI runs it on
a pull request that changes the image, with the deployment's type check.

The [pepys image workflow](../../../.github/workflows/pepys-image.yml) runs the same checks on a
push to `main`, then writes the context and publishes the image as
`ghcr.io/zgeoff/cloud-pepys:<release>-<commit>`. The stack config's `pepys.image` pins its digest.

## Routes

[`deploy/pepys/ingest-routes.json`](../../../deploy/pepys/ingest-routes.json) lists ingest's routes,
each marked `public` or `private`, and the secret variables ingest reads: each receive route's
secret and each pull path's `env`. It must match the deployment's plug-ins, and
[`check-pepys-routes.ts`](../../../scripts/check-pepys-routes.ts) checks that it does. The Pulumi
program cannot load the plug-ins, so it reads this file instead.

The shared tunnel carries the `public` routes to ingest at `pepys-webhook.geoff.cloud`, by one path
pattern anchored at both ends. It answers 404 on every other path of that host. Ingest checks the
signature of every GitHub delivery.

The telemetry routes are `private`, and no route reaches them yet. Ingest refuses a telemetry export
without a proven sender. The trust documents of the sender proof are the JSON files in
`deploy/pepys/imp-issuers/`, which a ConfigMap mounts at `PEPYS_IMP_IDENTITY_ISSUERS`, and the
audience is the stack config's `pepys.impIdentityAudience`, `pepys.imp.internal`. The folder holds
`geoffcloud.json`, the public key of the issuer `geoffcloud`, so ingest accepts an export whose
identity token that issuer signed for that audience, and refuses every other export. An invalid
document stops ingest at start.

The ingest Service has the pinned ClusterIP that `pepysIngest` in
[`constants.json`](../../../packages/topology/constants.json) names, so a relay on the host can dial
it.

## Network policies

Each pod admits only its callers:

- Garage admits s2-lite and the backup on 3900.
- s2-lite admits ingest and the host.
- ingest admits only the shared tunnel's cloudflared.
- The host and the backup admit no pod, so no route reaches the API yet. Until the tailnet route in
  [Later work](#later-work) exists, reach the API with `kubectl port-forward`.

Unlike every other namespace, pepys denies all egress, because ingest takes traffic from the
internet. Its namespace sets `egress: 'deny-all'` in
[`cluster-namespaces.ts`](../../../infra/shared/cluster-namespaces.ts), so each pod dials only what
its own policy in
[`build-pepys-egress-policy-specs.ts`](../../../infra/shared/build-pepys-egress-policy-specs.ts)
lists:

- Garage dials nothing: it runs one node on a loopback RPC address.
- s2-lite reaches DNS and Garage on 3900.
- ingest reaches DNS, s2-lite on 8080, and the internet on TCP 443 for the GitHub API. The rule
  excludes the cluster's pod and Service ranges, the tailnet, Podman's subnet, the private ranges
  and link-local. It still allows the node's own public address on 443.
- The host and the API reach DNS and s2-lite. The host keeps no blob, so it never calls Garage.
- The backup reaches DNS, Garage, and the internet on TCP 443 for R2, by the same rule as ingest.

No pepys pod mounts a service account token, so none needs the Kubernetes API. DNS selects the
CoreDNS pods, because a policy sees the address after kube-proxy's DNAT. The
[network policy check](../../../nixos/checks/network-policy.nix) applies these policies in a VM.

## Secrets and the backup

Each workload reads its secrets from its own Kubernetes Secret, whose name Pulumi generates. A
changed value then replaces the Secret and rolls the workload.
[`load-pepys-inputs.ts`](../../../infra/inputs/load-pepys-inputs.ts) names each variable it reads
from `.env`. The backup variables are all or none: without them, the cluster runs no backup.

The backup copies each bucket to its own folder of an R2 bucket with `rclone copy`, which never
deletes a copied object. The host's store needs no backup: the host rebuilds it from the fact log.

## Deploy the first time

**CAUTION:** The first apply adds a public route. Its `Deploy prod` run holds on the tunnel route
change until the owner approves it, as [the prod apply job](../../runbooks/prod-apply.md) describes.

The Pulumi program deploys pepys only when stack config `pepys` exists, so the service merges first
and changes nothing in prod.

1. Merge the service. The `pepys image` workflow publishes
   `ghcr.io/zgeoff/cloud-pepys:<release>-<commit>` from `main`, and its run summary gives the
   digest.
2. In a PR, add the `pepys` object to `infra/Pulumi.prod.yaml`:

   ```yaml
   geoff-cloud:pepys:
     image: ghcr.io/zgeoff/cloud-pepys:<release>-<commit>@sha256:<digest>
     webhookHostname: pepys-webhook.geoff.cloud
     impIdentityAudience: pepys.imp.internal
   ```

   Run `bun run preview` and check that it adds the `pepys` namespace, its network policies,
   Secrets, Services and workloads, and the shared tunnel's rule and the proxied record for
   `pepys-webhook.geoff.cloud`, and changes nothing else. The backup CronJob comes only with the
   backup variables in `.env`.

3. Merge the PR, and approve the held `Deploy prod` run once its plan matches the preview.
4. Check that the workloads are up:

   ```bash
   ssh root@geoffcloud k3s kubectl -n pepys rollout status statefulset/pepys-host --timeout=300s
   ```

   Expect `statefulset rolling update complete`. Check `statefulset/pepys-garage`,
   `deployment/pepys-s2` and `deployment/pepys-ingest` the same way.

5. Check that the public route refuses an unsigned delivery:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://pepys-webhook.geoff.cloud/webhook/github
   ```

   Expect `401`.

## Later work

- A tailnet route to the API, through the cluster's Traefik, so a tailnet client reaches it without
  a port-forward.
