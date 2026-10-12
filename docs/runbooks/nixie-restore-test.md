# Test a nixie restore

The test restores the latest snapshot of nixie's backup into a scratch claim and starts a second
nixie on it, while the live nixie keeps running. [nixie](./nixie.md#back-up-and-restore) covers the
backup itself and a real restore. The second nixie has impd's address pointed at a dead port,
because its recovery would otherwise remove the live nixie's sandboxes. It opens both databases,
runs its migrations and integrity check, and listens, but never turns ready.

1. Create the scratch claim, and restore into it with `claimName: nixie-restore-check` in
   `deploy/nixie/restore-job.yaml`:

   ```bash
   ssh root@geoffcloud k3s kubectl create -f - < deploy/nixie/restore-check-claim.yaml
   sed 's/claimName: data-nixie-0/claimName: nixie-restore-check/' deploy/nixie/restore-job.yaml \
     | ssh root@geoffcloud k3s kubectl create -f -
   ```

   Expect both `integrity_check ok` lines in the Job's log.

2. Start the scratch nixie, with the live pod's image and Secret:

   ```bash
   sed 's#url: https://imps.geoff.cloud#url: http://127.0.0.1:1#' deploy/nixie/config.yaml \
     | ssh root@geoffcloud k3s kubectl -n nixie create configmap nixie-restore-check --from-file=config.yaml=/dev/stdin
   image=$(ssh root@geoffcloud k3s kubectl -n nixie get pod nixie-0 -o 'jsonpath={.spec.containers[?(@.name=="nixie")].image}')
   secrets=$(ssh root@geoffcloud k3s kubectl -n nixie get pod nixie-0 -o 'jsonpath={.spec.volumes[?(@.name=="secrets")].secret.secretName}')
   sed -e "s#NIXIE_IMAGE#$image#" -e "s#NIXIE_SECRETS#$secrets#" deploy/nixie/restore-check-pod.yaml \
     | ssh root@geoffcloud k3s kubectl create -f -
   ```

3. Check that it started:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie logs nixie-restore-check | grep -E '"(writer.started|http.listening)"'
   ssh root@geoffcloud k3s kubectl -n nixie exec nixie-restore-check -- bun /app/main.js health --live && echo live
   ```

   Expect a `writer.started` line with the schema version, an `http.listening` line, and `live`.

4. Remove the scratch nixie, its ConfigMap, the claim, and the restore Job:

   ```bash
   ssh root@geoffcloud k3s kubectl -n nixie delete pod/nixie-restore-check configmap/nixie-restore-check pvc/nixie-restore-check job/<job-name>
   ```
