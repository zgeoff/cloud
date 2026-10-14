# The GHCR pull token

k3s pulls the atc gateway's image and the backup image from GHCR, where both packages are private. A
pull Secret named `ghcr-pull` holds the login and token that k3s pulls them with, in each namespace
that runs one of the images: `atc` for the gateway and its backup, and `nixie` for nixie's backup.
[The atc gateway](../architecture/workloads/atc-gateway.md#the-gateway-pod) explains why the Secret
has a fixed name. This runbook rotates the token and checks a pull.

## What holds what

| Where                                       | Holds                                                             |
| ------------------------------------------- | ----------------------------------------------------------------- |
| vault `cloud`, item `ghcr-pull`             | the GitHub login (`username`) and the token (`credential`)        |
| vault `cloud-deploy`, item `ghcr-pull`      | the apply job's copy of the same two fields                       |
| `.env`                                      | `GHCR_PULL_USERNAME` and `GHCR_PULL_TOKEN`, as `op://` references |
| the Secret `ghcr-pull` in `atc` and `nixie` | the two values as a docker config, set by Pulumi from `.env`      |

The token is a classic personal access token, because GHCR accepts no fine-grained token for a
package pull. A classic token with `read:packages` reads every package the account can see, so the
token holds that one scope and nothing else.

Pulumi reads the token from the environment that `op run` resolves, keeps it as a Pulumi secret, and
sends it to the k3s API inside the Secret's request body. The token never appears on a command line,
so never pass it to `kubectl create secret docker-registry` or to `crictl pull --creds` by hand.

## Rotate the token

**CAUTION:** An apply changes the live estate. Check that no `Deploy prod` run is in progress first
(`gh run list --workflow deploy-prod.yml --status in_progress`), because two applies at once race on
the stack.

1. In GitHub's [personal access tokens (classic)](https://github.com/settings/tokens), generate a
   token with the scope `read:packages` only and an expiry date. Keep the old token until the last
   step.
2. From a clean checkout of the tag `deployed/prod`, check the baseline before the item changes:

   ```bash
   bun run drift
   ```

   Expect exit 0. Record the revision and the result.

3. Paste the new token into the `credential` field of the item `ghcr-pull` in the vault `cloud`, and
   into its copy in `cloud-deploy`. Put the expiry date in the item's notes.
4. From a clean current `main`, preview:

   ```bash
   bun run preview -- --refresh
   ```

   Expect an update to the Secret `atc-ghcr-pull`, and to `nixie-ghcr-pull` when nixie's backup is
   set, and nothing else. A changed token updates each Secret in place, so no pod restarts.

5. Apply, then check that nothing drifted:

   ```bash
   bun run up
   bun run drift
   ```

   Expect exit 0 from the drift check. Record the result.

6. [Check a pull](#check-a-pull) with the new token.
7. Delete the old token in GitHub.

## Check a pull

The kubelet pulls a pinned image only when the node lacks it, so a running pod proves nothing about
the current token. This check starts a pod that pulls the backup image every time, through the
Secret in `atc`, and runs `restic version` in it.

1. Start the pod. Replace `<backup_image_reference>` with the backup image's pinned reference from
   `atcGateway.backupImage` in `infra/Pulumi.prod.yaml`. The commands travel on SSH's stdin in a
   quoted heredoc, because SSH joins its arguments into one string that the remote shell parses
   again, which would strip the JSON's quotes:

   ```bash
   ssh root@geoffcloud bash -s <<'EOF'
   k3s kubectl -n atc run ghcr-pull-check --restart=Never \
     --image='<backup_image_reference>' --image-pull-policy=Always \
     --overrides='{"apiVersion":"v1","spec":{"imagePullSecrets":[{"name":"ghcr-pull"}]}}' \
     --command -- restic version
   EOF
   ```

2. Read its phase:

   ```bash
   ssh root@geoffcloud bash -s <<'EOF'
   k3s kubectl -n atc get pod ghcr-pull-check -o jsonpath='{.status.phase}'
   EOF
   ```

   Expect `Succeeded`. A phase of `Pending` with the event `Failed to pull image` and
   `401 Unauthorized` means GHCR refused the token. Read the events with
   `kubectl -n atc describe pod ghcr-pull-check`.

3. Remove the pod:

   ```bash
   ssh root@geoffcloud k3s kubectl -n atc delete pod ghcr-pull-check
   ```
