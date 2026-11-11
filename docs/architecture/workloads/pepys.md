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

[`pepys-workloads.ts`](../../../infra/cluster/pepys-workloads.ts) holds each name, port and
in-cluster URL. [`pepys-images.ts`](../../../infra/shared/pepys-images.ts) pins the three images
from their publishers, the same Garage and s2 builds that the pepys repo's test stack runs.

Garage starts with `--single-node`, which assigns its layout on the first start. Garage's two
secrets reach it through the environment, so [`garage.toml`](../../../deploy/pepys/garage.toml)
holds none. Garage, the host's store and their volumes use `local-path-retain`, so a deleted claim
keeps its data.

The host runs `pepys-host run --up`, which deploys each consumer that `/modules/consumers.json`
lists before it tails the streams. The API runs in the same pod and reads the store files that the
host writes. Ingest and the API listen on `0.0.0.0`, because each listens on 127.0.0.1 unless told
otherwise, and no Service reaches a loopback listener.

## The image

`cloud-pepys` holds three binaries and the consumer modules.
[`write-pepys-image-context.sh`](../../../scripts/write-pepys-image-context.sh) writes its build
context:

1. It downloads the host binary of the release that
   [`images/pepys/versions.env`](../../../images/pepys/versions.env) pins, and checks the binary
   against the release's `SHA256SUMS` and against the pin.
2. It runs `pepys build` on `deploy/pepys/deployment.ts` for the modules.
3. It compiles `deploy/pepys/ingest.ts` and `deploy/pepys/api.ts` with `bun build --compile`.

The `@pepys/*` packages in `package.json` carry the same version as `PEPYS_RELEASE`. So the binaries
and the modules always come from one release.

## Routes

[`deploy/pepys/ingest-routes.json`](../../../deploy/pepys/ingest-routes.json) lists ingest's routes,
each marked `public` or `private`, and the secret variables they check. It must match the receive
routes of the deployment's plug-ins. The Pulumi program cannot load the plug-ins, so it reads this
file instead.

The shared tunnel carries the `public` routes to ingest at `pepys-webhook.geoff.cloud`, by one path
pattern anchored at both ends. It answers 404 on every other path of that host. Ingest checks the
signature of every GitHub delivery.

The telemetry routes are `private`. Ingest refuses a telemetry export without a proven sender. The
trust documents of the sender proof are the JSON files in `deploy/pepys/imp-issuers/`, mounted at
`PEPYS_IMP_IDENTITY_ISSUERS`. With no document there, ingest refuses every export.

## Network policies

Each pod admits only its callers:

- Garage admits s2-lite and the backup on 3900.
- s2-lite admits ingest and the host.
- ingest admits only the shared tunnel's cloudflared.
- The host and the backup admit no pod. The owner reaches the API with `kubectl port-forward`.

The namespace's egress deny refuses every pod the tailnet and Podman's subnet, as in every other
namespace.

## Secrets and the backup

Each workload reads its secrets from its own Kubernetes Secret, whose name Pulumi generates. A
changed value then replaces the Secret and rolls the workload.
[`load-pepys-inputs.ts`](../../../infra/inputs/load-pepys-inputs.ts) names each variable it reads
from `.env`. The backup variables are all or none: without them, the cluster runs no backup.

The backup copies each bucket to its own folder of an R2 bucket with `rclone copy`, which never
deletes a copied object. The host's store needs no backup: the host rebuilds it from the fact log.
