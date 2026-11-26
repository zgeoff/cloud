# The GHCR pull token

k3s pulls several workloads' images from GHCR, where the packages are private: the atc gateway and
its backup, nixie's backup, pepys, boxxy and files. A pull Secret named `ghcr-pull` holds the login
and token that k3s pulls them with, in each namespace that runs one of the images. The Secret has a
fixed name for the reason in
[the atc gateway](../architecture/workloads/atc-gateway.md#the-gateway-pod). Use this runbook to
rotate the token and to check a pull.

## What holds what

| Where                                              | Holds                                                             |
| -------------------------------------------------- | ----------------------------------------------------------------- |
| vault `cloud`, item `ghcr-pull`                    | the GitHub login (`username`) and the token (`credential`)        |
| vault `cloud-deploy`, item `ghcr-pull`             | the apply job's copy of the same two fields                       |
| `.env`                                             | `GHCR_PULL_USERNAME` and `GHCR_PULL_TOKEN`, as `op://` references |
| the Secret `ghcr-pull` in each of those namespaces | the two values as a docker config, set by Pulumi from `.env`      |

The token is a classic personal access token, because GHCR accepts no fine-grained token for a
package pull. Give the token the `read:packages` scope and nothing else: that one scope reads every
package the account can see.

Pulumi reads the token from the environment that `op run` resolves, keeps it as a Pulumi secret, and
sends it to the k3s API inside the Secret's request body. Keep the token off every command line:
never pass it to `kubectl create secret docker-registry` or to `crictl pull --creds` by hand.

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

   Expect an update to each pull Secret and nothing else. In the preview, each Secret appears under
   its Pulumi resource name, such as `atc-ghcr-pull` or `pepys-ghcr-pull`, one for each workload the
   stack sets. A changed token updates each Secret in place, so no pod restarts.

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
the current token. To check the token, start a pod that pulls the backup image every time, through
the Secret in `atc`, and run `restic version` in it.

1. Start the pod. Replace `<backup_image_reference>` with the backup image's pinned reference from
   `atcGateway.backupImage` in `infra/Pulumi.prod.yaml`. Send the commands on SSH's stdin in a
   quoted heredoc. SSH joins its arguments into one string that the remote shell parses again, which
   would strip the JSON's quotes:

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
   `ssh root@geoffcloud k3s kubectl -n atc describe pod ghcr-pull-check`.

3. Remove the pod:

   ```bash
   ssh root@geoffcloud k3s kubectl -n atc delete pod ghcr-pull-check
   ```
