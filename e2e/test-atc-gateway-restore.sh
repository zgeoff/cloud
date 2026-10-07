#!/usr/bin/env bash
# End-to-end journey: an operator restores the atc gateway's state from a backup, as
# docs/runbooks/atc-gateway-backup-restore.md describes, run locally with Docker. It
# touches no cluster and no cloud account.
#
# The gateway runs as the Deployment runs it (infra/build-atc-gateway-spec.ts), and the
# backup image as the backup CronJob and the restore Job run it
# (infra/build-atc-gateway-backup-pod-spec.ts, deploy/atc-gateway/restore-job.yaml).
# The journey adds a client, backs the live databases up, wipes them, restores them and
# starts a new gateway, which still knows the client. Each step needs the state the step
# before it left, so the journey checks each step as it goes.
#
# The images come from scripts/test-lib/with-fixture-images.sh, which builds them once
# per run under tags carrying a random per-run id, removes them after, and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE. The journey runs its own
# containers on its own volumes, all named from that id, and removes them when it exits.
# `bun run test:atc-gateway-fixture` runs it after the fixture tests; alone:
#
#   bash scripts/test-lib/with-fixture-images.sh bash e2e/test-atc-gateway-restore.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-lib/start-gateway.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-lib/wait-for-ready.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-lib/run-backup.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-lib/run-backup-shell.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-lib/normalize-restic-output.sh"

# A backup reads the live databases while the gateway runs; the restore goes into the
# volume after the databases are wiped, and a new container finds the client again. The
# backup and the restore run as their production pods do, so the restored files carry the
# restore's own uid and the modes the gateway gave them, with no chown after it.
it_restores_a_stored_client_after_a_backup_a_wipe_and_a_restore() {
  local gateway_image="$1" backup_image="$2" client_id
  name="atc-gw-restore-$4-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  docker exec "$name" /usr/local/bin/atc-gateway clients add fixture-client \
    --redirect-uri https://client.fixture.invalid/callback > "$tree/added"
  client_id="$(sed -n 's/^Added fixture-client\. Its client ID is \([A-Za-z0-9]*\)$/\1/p' "$tree/added")"
  [ -n "$client_id" ] || { cat "$tree/added"; echo "no client ID in the add output" >&2; exit 1; }

  run_backup "$name" "$backup_image" backup > "$tree/backup.out" 2> "$tree/backup.err"

  diff /dev/null "$tree/backup.err"
  # the repository's id is generated at init, so it is masked like a snapshot ID
  normalize_restic_output < "$tree/backup.out" |
    sed -E 's/^created restic repository [0-9a-f]+ at /created restic repository ID at /' > "$tree/backup.normal"
  diff - "$tree/backup.normal" << 'EOF'
created restic repository ID at /repo

Please note that knowledge of your password is required to access
the repository. Losing your password means that your data is
irrecoverably lost.
no parent snapshot found, will read all files

Files:           2 new,     0 changed,     0 unmodified
Dirs:            0 new,     0 changed,     0 unmodified
Added to the repository: SIZE (SIZE stored)

processed 2 files, SIZE in T
snapshot ID saved
Applying Policy: keep 7 daily, 4 weekly snapshots
keep 1 snapshots:
ID        Time                 Host         Tags         Reasons          Paths                    Size
--------------------------------------------------------------------------------------------------------------
ID  NOW  atc-gateway  atc-gateway  daily snapshot   /tmp/atc-gateway-backup  SIZE
                                                         weekly snapshot
--------------------------------------------------------------------------------------------------------------
1 snapshots

EOF

  docker stop "$name" > /dev/null
  docker rm "$name" > /dev/null
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'rm -f /state/*.db*; ls -A /state' > "$tree/wiped"

  diff /dev/null "$tree/wiped"

  run_backup "$name" "$backup_image" restore > "$tree/restore.out" 2> "$tree/restore.err"

  diff /dev/null "$tree/restore.err"
  normalize_restic_output < "$tree/restore.out" > "$tree/restore.normal"
  diff - "$tree/restore.normal" << 'EOF'
restoring snapshot ID of [/tmp/atc-gateway-backup] at NOW +0000 UTC by @atc-gateway to /tmp/tmp.X
Summary: Restored 2 files/dirs (SIZE) in T
EOF

  start_gateway "$name" "$tree" "$gateway_image"

  run_backup_shell "$name" "$backup_image" "$tree" <<< 'cd /state && stat -c "%n %u %g %a" *.db' > "$tree/restored"
  diff - "$tree/restored" << 'EOF'
gateway.db 65532 65532 644
mcp-auth.db 65532 65532 600
EOF
  docker exec "$name" /usr/local/bin/atc-gateway clients list > "$tree/clients"
  diff - "$tree/clients" <<< "$client_id  fixture-client  https://client.fixture.invalid/callback"
}

# Boot data the journey needs: the registry the gateway reads, whose daemon is a dead
# address (the gateway serves without reaching it), a seed directory the backup shell
# reads at /seed, and a state volume and a restic repository volume owned by the nonroot
# uid, as fsGroup 65532 leaves the pod's new volume.
setup_test() {
  local tree="$1" name="$2" restic_image="$3"
  mkdir "$tree/registry" "$tree/seed"
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rwX "$tree/seed"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh \
    -v "$name-state:/s" -v "$name-repo:/r" "$restic_image" -c 'chown 65532:65532 /s /r'
}

# Boot data every case needs: the pinned restic image that setup_test chowns the volumes
# with, and the images and the run id that with-fixture-images.sh provides.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# sets RESTIC_IMAGE, among the pins
# shellcheck source=/dev/null
source "$repo/deploy/atc-gateway/versions.env"
: "${FIXTURE_RUN:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
: "${FIXTURE_GATEWAY_IMAGE:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
: "${FIXTURE_BACKUP_IMAGE:?is unset: run this under scripts/test-lib/with-fixture-images.sh}"
# shellcheck disable=SC2153 # RESTIC_IMAGE comes from versions.env
run_cases "$FIXTURE_GATEWAY_IMAGE" "$FIXTURE_BACKUP_IMAGE" "$RESTIC_IMAGE" "$FIXTURE_RUN"
