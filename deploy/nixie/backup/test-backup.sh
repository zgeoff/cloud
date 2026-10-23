#!/usr/bin/env bash
# Fixture test for nixie's backup script (backup.sh), run locally with Docker in the backup image
# that the stack config pins as atcGateway.backupImage. It touches no cluster and no cloud account.
#
# It runs the script as the backup CronJob and the restore Job run it
# (infra/cluster/build-nixie-backup-pod-spec.ts, infra/cluster/build-nixie-restore-pod-spec.ts):
# nixie's uid and gid 10001, the script mounted read-only and run by /bin/sh in place of the
# image's entrypoint, the directory nixie's commands share with it at /tmp/nixie-backup, and a
# local restic repository at /repo. The copy is opaque files, because nixie's own backup and
# restore commands read and write nixie's databases, and their tests live in nixie. What this
# proves: a backup uploads the copy it finds and nothing else, and stops before restic when there
# is none; retention prunes nixie's snapshots and leaves another tool's alone; a restore writes the
# snapshot into an empty copy directory and refuses one that is not empty; and SNAPSHOT, ls and the
# usage. What it does not prove: R2, k3s, and nixie's commands, which the restore test in
# docs/runbooks/nixie-backup.md covers.
#
# `bun run test:nixie-backup-fixture` runs it; one case alone:
#
#   CASE='ls mode' bash deploy/nixie/backup/test-backup.sh
# shell-suite: nixie-backup-fixture
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../test-support/shell/run-backup.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../test-support/shell/run-backup-shell.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../test-support/shell/normalize-restic-output.sh"

it_uploads_the_copy_that_nixie_backup_left_and_nothing_else() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-copy" "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -v "$name-copy:/tmp/nixie-backup" << 'EOF'
echo 'the first copy' > /tmp/nixie-backup/one
echo 'the second copy' > /tmp/nixie-backup/two
echo 'outside the copy' > /state/other
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$name-copy:/tmp/nixie-backup" -v "$script:/opt/nixie-backup/backup.sh:ro" \
    /opt/nixie-backup/backup.sh backup > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  # the table's rules run as wide as its size column, which the size it masks sets
  normalize_restic_output < "$tree/out" | sed -E 's/^-{20,}$/RULE/' > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
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
ID        Time                 Host        Tags        Reasons          Paths              Size
RULE
ID  NOW  nixie       nixie       daily snapshot   /tmp/nixie-backup  SIZE
                                                       weekly snapshot
RULE
1 snapshots

EOF
  assert_status 0 "$status"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 > "$tree/snapshot" << 'EOF'
restic ls --tag nixie --host nixie latest | tail -n +2
restic dump latest /one
restic dump latest /two
EOF
  diff - "$tree/snapshot" << 'EOF'
/one
/two
the first copy
the second copy
EOF
}

it_fails_a_backup_before_restic_when_nixie_backup_left_no_copy() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-copy" "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$name-copy:/tmp/nixie-backup" -v "$script:/opt/nixie-backup/backup.sh:ro" \
    /opt/nixie-backup/backup.sh backup > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'no copy from nixie backup in /tmp/nixie-backup'
  diff /dev/null "$tree/out"
  assert_status 1 "$status"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 <<< 'ls -A /repo' > "$tree/left"
  diff /dev/null "$tree/left"
}

# Three nixie snapshots from earlier runs, each from its own path, all on one fixed day, and one
# other tool's snapshot older than all of them: grouped by host and tags, retention keeps the
# newest of that day (old-c) and the group's oldest (old-a) and forgets old-b; the other tool's
# snapshot stays.
it_prunes_nixies_snapshots_and_leaves_another_tools_alone() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-copy" "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -v "$name-copy:/tmp/nixie-backup" << 'EOF'
restic init -q
for s in a:10 b:11 c:12; do
  d="/tmp/old-${s%%:*}"
  mkdir -p "$d" && echo old > "$d/one"
  (cd "$d" && restic backup -q --tag nixie --host nixie --time "2020-01-06 ${s#*:}:00:00" .)
done
mkdir -p /tmp/other && echo other > /tmp/other/f
(cd /tmp/other && restic backup -q --tag other --host other --time "2020-01-06 09:00:00" .)
echo 'the copy' > /tmp/nixie-backup/one
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$name-copy:/tmp/nixie-backup" -v "$script:/opt/nixie-backup/backup.sh:ro" \
    /opt/nixie-backup/backup.sh backup > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  assert_status 0 "$status"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 <<< 'restic snapshots --json' > "$tree/snapshots"
  jq -r '[.[] | "\(.hostname) \(.paths[0]) \(if .paths == ["/tmp/nixie-backup"] then "NOW" else .time end)"] | sort[]' \
    "$tree/snapshots" > "$tree/kept"
  diff - "$tree/kept" << 'EOF'
nixie /tmp/nixie-backup NOW
nixie /tmp/old-a 2020-01-06T10:00:00Z
nixie /tmp/old-c 2020-01-06T12:00:00Z
other /tmp/other 2020-01-06T09:00:00Z
EOF
}

# The restore writes the latest snapshot's files into the copy directory as nixie's uid, where the
# restore pod's nixie restore reads them.
it_restores_the_latest_snapshot_into_an_empty_copy_directory() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-copy" "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
mkdir /tmp/snap
echo 'the first copy' > /tmp/snap/one
echo 'the second copy' > /tmp/snap/two
(cd /tmp/snap && restic backup -q --tag nixie --host nixie --time "2020-01-06 10:00:00" .)
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$name-copy:/tmp/nixie-backup" -v "$script:/opt/nixie-backup/backup.sh:ro" \
    /opt/nixie-backup/backup.sh restore > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @nixie to /tmp/nixie-backup
Summary: Restored 2 files/dirs (SIZE) in T
EOF
  assert_status 0 "$status"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -v "$name-copy:/tmp/nixie-backup" > "$tree/copy" << 'EOF'
cd /tmp/nixie-backup && stat -c '%n %u:%g' * | sort
cat one two
EOF
  diff - "$tree/copy" << 'EOF'
one 10001:10001
two 10001:10001
the first copy
the second copy
EOF
}

# A copy directory that holds files already would mix them into the restore, so the script stops
# before restic and leaves them.
it_refuses_a_restore_into_a_copy_directory_that_is_not_empty() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-copy" "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -v "$name-copy:/tmp/nixie-backup" << 'EOF'
restic init -q
mkdir /tmp/snap
echo 'from the snapshot' > /tmp/snap/one
(cd /tmp/snap && restic backup -q --tag nixie --host nixie --time "2020-01-06 10:00:00" .)
echo 'already here' > /tmp/nixie-backup/one
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$name-copy:/tmp/nixie-backup" -v "$script:/opt/nixie-backup/backup.sh:ro" \
    /opt/nixie-backup/backup.sh restore > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< '/tmp/nixie-backup is not empty'
  diff /dev/null "$tree/out"
  assert_status 1 "$status"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -v "$name-copy:/tmp/nixie-backup" <<< \
    'cat /tmp/nixie-backup/one' > "$tree/copy"
  diff - "$tree/copy" <<< 'already here'
}

it_restores_the_snapshot_that_SNAPSHOT_names_instead_of_the_latest() {
  local image="$1" script="$2" older status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-copy" "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
mkdir /tmp/snap
echo older > /tmp/snap/one
(cd /tmp/snap && restic backup -q --tag nixie --host nixie --time "2020-01-06 10:00:00" .)
echo newer > /tmp/snap/one
(cd /tmp/snap && restic backup -q --tag nixie --host nixie --time "2020-01-07 10:00:00" .)
EOF
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 <<< 'restic snapshots --json' > "$tree/snapshots"
  older="$(jq -r '.[] | select(.time == "2020-01-06T10:00:00Z") | .short_id' "$tree/snapshots")"
  [ -n "$older" ] || {
    echo "no snapshot from 2020-01-06" >&2
    exit 1
  }

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh -e "SNAPSHOT=$older" \
    -v "$name-copy:/tmp/nixie-backup" -v "$script:/opt/nixie-backup/backup.sh:ro" \
    /opt/nixie-backup/backup.sh restore > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  assert_status 0 "$status"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -v "$name-copy:/tmp/nixie-backup" <<< \
    'cat /tmp/nixie-backup/one' > "$tree/value"
  diff - "$tree/value" <<< older
}

# ls lists nixie's snapshots alone; each ID is random, so the case masks that column
it_lists_nixies_snapshots_alone_in_ls_mode() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-copy" "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
mkdir /tmp/a /tmp/other && echo a > /tmp/a/one && echo other > /tmp/other/f
(cd /tmp/a && restic backup -q --tag nixie --host nixie --time "2020-01-06 10:00:00" .)
(cd /tmp/other && restic backup -q --tag other --host other --time "2020-01-06 09:00:00" .)
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh ls \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
ID        Time                 Host        Tags        Paths   Size
-------------------------------------------------------------------
ID  2020-01-06 10:00:00  nixie       nixie       /tmp/a  SIZE
-------------------------------------------------------------------
1 snapshots
EOF
  assert_status 0 "$status"
}

it_rejects_an_unknown_mode_with_its_usage() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-copy" "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh prune \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: nixie-backup backup|restore|ls'
  diff /dev/null "$tree/out"
  assert_status 2 "$status"
}

# Boot data every case needs: a seed directory the backup shell reads at /seed, and a copy volume,
# a state volume and a restic repository volume owned by nixie's uid, as fsGroup 10001 leaves the
# pod's volumes. The copy volume stands in for the pod's shared /tmp, which the helpers mount as a
# tmpfs of each container's own. Its chown container is named for the case's trap.
setup_test() {
  local tree="$1" name="$2" image="$3"
  mkdir "$tree/seed"
  chmod -R a+rwX "$tree/seed"
  chmod -R a+rX "$tree"
  docker volume create "$name-copy" > /dev/null
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh \
    -v "$name-copy:/c" -v "$name-state:/s" -v "$name-repo:/r" "$image" \
    -c 'chown 10001:10001 /c /s /r'
}

# Boot data every case needs: the backup image the stack config pins for nixie and the gateway
# (atcGateway.backupImage), pulled once, and the script under test, by absolute path for the bind
# mount.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
image="$(cd "$repo" && bun -e 'console.log(Bun.YAML.parse(await Bun.file("infra/Pulumi.prod.yaml").text()).config["geoff-cloud:atcGateway"].backupImage)')"
docker pull -q "$image" > /dev/null
run="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
run_cases "$image" "$repo/deploy/nixie/backup/backup.sh" "$run"
