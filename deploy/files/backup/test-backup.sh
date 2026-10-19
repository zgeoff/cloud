#!/usr/bin/env bash
# Fixture test for the files service's backup script (backup.sh), run locally with Docker in the
# backup image that the stack config pins as atcGateway.backupImage. It touches no cluster and no
# cloud account.
#
# It runs the script as the backup CronJob and the restore Job run it
# (infra/cluster/build-files-backup-pod-spec.ts, deploy/files/restore-job.yaml): the service's uid
# and gid 65532, the script mounted read-only and run by /bin/sh in place of the image's
# entrypoint, the state volume at /state and a local restic repository at /repo. What this proves:
# a backup takes a consistent copy of files.db, with the rows still in a live writer's WAL, and the
# files/ directory, and leaves incoming/ and the live database out; it stops before restic without
# files.db, and while another job holds the lock; a restore checks the metadata copy, and stages it
# on the volume, before it changes anything, then brings back the files and the metadata of one
# snapshot, the one SNAPSHOT names if set, drops the old WAL files, and removes each file the
# metadata does not list; and ls and the usage. What it does not prove: R2, k3s, and the service starting on a
# restored volume, which the restore check in docs/runbooks/files.md covers.
#
# `bun run test:files-backup-fixture` runs it; one case alone, or against a local build of the
# backup image (images/atc-gateway/backup) in place of the pinned one:
#
#   CASE='ls mode' bash deploy/files/backup/test-backup.sh
#   BACKUP_IMAGE=<local tag> bash deploy/files/backup/test-backup.sh
# shell-suite: files-backup-fixture
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

it_backs_up_the_metadata_copy_and_the_files_and_leaves_the_rest_out() {
  local image="$1" script="$2" status=0
  name="files-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" << 'EOF'
sqlite3 /state/files.db "CREATE TABLE uploads (id TEXT PRIMARY KEY); INSERT INTO uploads VALUES ('AAAAAAAAAAAAAAAAAAAAAA');"
mkdir /state/files /state/incoming
echo 'a screenshot' > /state/files/AAAAAAAAAAAAAAAAAAAAAA
echo 'half written' > /state/incoming/BBBBBBBBBBBBBBBBBBBBBB
EOF

  run_backup "$name" "$image" --entrypoint /bin/sh \
    -v "$script:/opt/files-backup/backup.sh:ro" /opt/files-backup/backup.sh backup \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
created restic repository ID at /repo

Please note that knowledge of your password is required to access
the repository. Losing your password means that your data is
irrecoverably lost.
no parent snapshot found, will read all files

Files:           2 new,     0 changed,     0 unmodified
Dirs:            1 new,     0 changed,     0 unmodified
Added to the repository: SIZE (SIZE stored)

processed 2 files, SIZE in T
snapshot ID saved
Applying Policy: keep 7 daily, 4 weekly snapshots
keep 1 snapshots:
ID        Time                 Host        Tags        Reasons          Paths                   Size
----------------------------------------------------------------------------------------------------------
ID  NOW  files       files       daily snapshot   /state/files            SIZE
                                                       weekly snapshot  /state/files-backup.db
----------------------------------------------------------------------------------------------------------
1 snapshots

EOF
  assert_status 0 "$status"
  run_backup_shell "$name" "$image" "$tree" > "$tree/snapshot" << 'EOF'
restic ls --tag files --host files latest | tail -n +2
restic dump latest /files-backup.db > /tmp/copy.db && sqlite3 /tmp/copy.db 'SELECT id FROM uploads'
ls /state
EOF
  diff - "$tree/snapshot" << 'EOF'
/files
/files/AAAAAAAAAAAAAAAAAAAAAA
/files-backup.db
AAAAAAAAAAAAAAAAAAAAAA
files
files.db
incoming
EOF
}

# A writer holds files.db open in WAL mode, as the service does, and its last row is still in the
# WAL when the backup runs. The backup runs inside the same container as the writer, so the writer
# stays open; the case reads the row back from the snapshot.
it_backs_up_the_rows_in_a_live_writers_wal() {
  local image="$1" script="$2"
  name="files-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"

  run_backup_shell "$name" "$image" "$tree" -e STATE_DIR=/state \
    -v "$script:/opt/files-backup/backup.sh:ro" > "$tree/out" << 'EOF'
sqlite3 /state/files.db 'PRAGMA journal_mode=WAL; CREATE TABLE uploads (id TEXT PRIMARY KEY);' > /dev/null
{
  echo "INSERT INTO uploads VALUES ('CCCCCCCCCCCCCCCCCCCCCC');"
  sleep 60
} | sqlite3 /state/files.db > /dev/null &
writer=$!
i=0
until [ "$(sqlite3 /state/files.db 'SELECT count(*) FROM uploads' 2> /dev/null)" = 1 ]; do
  i=$((i + 1)); [ "$i" -lt 100 ] || exit 1; sleep 0.1
done
[ -s /state/files.db-wal ] && echo "wal before: present"
/bin/sh /opt/files-backup/backup.sh backup > /dev/null
kill "$writer"
restic dump latest /files-backup.db > /tmp/copy.db
sqlite3 /tmp/copy.db 'SELECT id FROM uploads'
EOF

  diff - "$tree/out" << 'EOF'
wal before: present
CCCCCCCCCCCCCCCCCCCCCC
EOF
}

it_stops_before_restic_without_files_db() {
  local image="$1" script="$2" status=0
  name="files-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"

  run_backup "$name" "$image" --entrypoint /bin/sh \
    -v "$script:/opt/files-backup/backup.sh:ro" /opt/files-backup/backup.sh backup \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'no files.db in /state'
  assert_status 1 "$status"
  run_backup_shell "$name" "$image" "$tree" > "$tree/repo" << 'EOF'
ls -A /repo
EOF
  diff /dev/null "$tree/repo"
}

# The service wrote one upload after the backup's metadata copy, and left a WAL beside its
# database; the restore brings back the snapshot's file and row, drops the WAL, and removes the
# later file, which no restored row lists.
it_restores_the_files_and_the_metadata_and_removes_a_file_without_a_row() {
  local image="$1" script="$2" status=0
  name="files-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" -e STATE_DIR=/state \
    -v "$script:/opt/files-backup/backup.sh:ro" << 'EOF'
sqlite3 /state/files.db "CREATE TABLE uploads (id TEXT PRIMARY KEY); INSERT INTO uploads VALUES ('AAAAAAAAAAAAAAAAAAAAAA');"
mkdir /state/files
echo 'a screenshot' > /state/files/AAAAAAAAAAAAAAAAAAAAAA
/bin/sh /opt/files-backup/backup.sh backup > /dev/null
rm /state/files/AAAAAAAAAAAAAAAAAAAAAA
sqlite3 /state/files.db "DELETE FROM uploads; INSERT INTO uploads VALUES ('DDDDDDDDDDDDDDDDDDDDDD');"
echo 'a later upload' > /state/files/DDDDDDDDDDDDDDDDDDDDDD
echo 'stale wal' > /state/files.db-wal
EOF

  run_backup "$name" "$image" --entrypoint /bin/sh \
    -v "$script:/opt/files-backup/backup.sh:ro" /opt/files-backup/backup.sh restore \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/state/files-backup.db /state/files] at NOW +0000 UTC by @files to /tmp/tmp.X
Summary: Restored 1 files/dirs (SIZE) in T
restoring snapshot ID of [/state/files-backup.db /state/files] at NOW +0000 UTC by @files to /state
Summary: Restored 2 files/dirs (SIZE) in T
restored files.db: integrity_check ok, 1 uploads, 1 files without a row removed
EOF
  assert_status 0 "$status"
  run_backup_shell "$name" "$image" "$tree" > "$tree/state" << 'EOF'
ls -A /state /state/files
cat /state/files/AAAAAAAAAAAAAAAAAAAAAA
sqlite3 /state/files.db 'SELECT id FROM uploads'
EOF
  diff - "$tree/state" << 'EOF'
/state:
.files-backup.lock
files
files.db

/state/files:
AAAAAAAAAAAAAAAAAAAAAA
a screenshot
AAAAAAAAAAAAAAAAAAAAAA
EOF
}

# A snapshot whose metadata copy is not a database: the restore stops before it touches the state.
it_stops_a_restore_before_any_change_when_the_metadata_copy_fails_its_check() {
  local image="$1" script="$2" status=0
  name="files-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" << 'EOF'
restic init > /dev/null
mkdir -p /tmp/snap/files
echo 'not a database' > /tmp/snap/files-backup.db
(cd /tmp/snap && restic backup --tag files --host files files-backup.db files > /dev/null)
sqlite3 /state/files.db "CREATE TABLE uploads (id TEXT PRIMARY KEY); INSERT INTO uploads VALUES ('LIVELIVELIVELIVELIVELI');"
EOF

  run_backup "$name" "$image" --entrypoint /bin/sh \
    -v "$script:/opt/files-backup/backup.sh:ro" /opt/files-backup/backup.sh restore \
    > "$tree/out" 2> "$tree/err" || status=$?

  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap/files-backup.db /tmp/snap/files] at NOW +0000 UTC by @files to /tmp/tmp.X
Summary: Restored 1 files/dirs (SIZE) in T
EOF
  diff - "$tree/err" << 'EOF'
Error: in prepare, file is not a database (26)
the restored files-backup.db failed the integrity check
EOF
  assert_status 1 "$status"
  run_backup_shell "$name" "$image" "$tree" > "$tree/state" << 'EOF'
ls -A /state
sqlite3 /state/files.db 'SELECT id FROM uploads'
EOF
  diff - "$tree/state" << 'EOF'
.files-backup.lock
files.db
LIVELIVELIVELIVELIVELI
EOF
}

# Another job holds the lock, as a manual job does beside the CronJob's run: the backup stops
# before it makes or removes a metadata copy, and saves no snapshot.
it_refuses_a_backup_while_another_job_holds_the_lock() {
  local image="$1" script="$2"
  name="files-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"

  run_backup_shell "$name" "$image" "$tree" -e STATE_DIR=/state \
    -v "$script:/opt/files-backup/backup.sh:ro" > "$tree/out" 2> "$tree/err" << 'EOF'
sqlite3 /state/files.db "CREATE TABLE uploads (id TEXT PRIMARY KEY);"
echo 'the other job' > /state/files-backup.db
exec 8> /state/.files-backup.lock
flock -n 8
status=0
/bin/sh /opt/files-backup/backup.sh backup || status=$?
echo "status $status"
cat /state/files-backup.db
ls -A /repo
EOF

  diff - "$tree/err" <<< 'another files-backup job holds /state/.files-backup.lock'
  diff - "$tree/out" << 'EOF'
status 1
the other job
EOF
}

# Two snapshots, the later with another upload: SNAPSHOT names the earlier, and the restore brings
# back that snapshot's metadata and files, not the latest one's. The later snapshot comes from
# restic directly, since the script's retention keeps one snapshot a day.
it_restores_the_snapshot_that_snapshot_names_rather_than_the_latest() {
  local image="$1" script="$2" status=0
  name="files-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" -e STATE_DIR=/state \
    -v "$script:/opt/files-backup/backup.sh:ro" > "$tree/first" << 'EOF'
sqlite3 /state/files.db "CREATE TABLE uploads (id TEXT PRIMARY KEY); INSERT INTO uploads VALUES ('EEEEEEEEEEEEEEEEEEEEEE');"
mkdir /state/files
echo 'the first upload' > /state/files/EEEEEEEEEEEEEEEEEEEEEE
/bin/sh /opt/files-backup/backup.sh backup > /dev/null
restic snapshots --json --tag files --host files latest | sed -n 's/.*[{,]"id":"\([0-9a-f]\{64\}\)".*/\1/p'
sqlite3 /state/files.db "INSERT INTO uploads VALUES ('FFFFFFFFFFFFFFFFFFFFFF');"
echo 'the second upload' > /state/files/FFFFFFFFFFFFFFFFFFFFFF
sqlite3 /state/files.db ".backup '/state/files-backup.db'"
(cd /state && restic backup --tag files --host files files-backup.db files > /dev/null)
rm /state/files-backup.db
EOF

  run_backup "$name" "$image" --entrypoint /bin/sh -e "SNAPSHOT=$(cat "$tree/first")" \
    -v "$script:/opt/files-backup/backup.sh:ro" /opt/files-backup/backup.sh restore \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  tail -n 1 "$tree/out" > "$tree/summary"
  diff - "$tree/summary" <<< 'restored files.db: integrity_check ok, 1 uploads, 1 files without a row removed'
  assert_status 0 "$status"
  run_backup_shell "$name" "$image" "$tree" > "$tree/state" << 'EOF'
ls /state/files
cat /state/files/EEEEEEEEEEEEEEEEEEEEEE
sqlite3 /state/files.db 'SELECT id FROM uploads'
EOF
  diff - "$tree/state" << 'EOF'
EEEEEEEEEEEEEEEEEEEEEE
the first upload
EEEEEEEEEEEEEEEEEEEEEE
EOF
}

# The state volume is a small tmpfs with too little room left for the snapshot's metadata copy:
# the restore stops at the staging copy, before it changes the live database or the files. A tmpfs
# volume empties when no container mounts it, so the setup, the restore and the check share one.
it_stops_a_restore_before_any_change_when_the_metadata_does_not_fit_on_the_volume() {
  local image="$1" script="$2"
  name="files-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  docker volume rm "$name-state" > /dev/null
  docker volume create --driver local --opt type=tmpfs --opt device=tmpfs \
    --opt o=size=1m,uid=65532,gid=65532 "$name-state" > /dev/null

  run_backup_shell "$name" "$image" "$tree" -e STATE_DIR=/state \
    -v "$script:/opt/files-backup/backup.sh:ro" > "$tree/out" << 'EOF'
restic init > /dev/null
mkdir -p /tmp/snap/files
sqlite3 /tmp/snap/files-backup.db "CREATE TABLE uploads (id TEXT PRIMARY KEY, pad BLOB); INSERT INTO uploads VALUES ('GGGGGGGGGGGGGGGGGGGGGG', zeroblob(600000));"
(cd /tmp/snap && restic backup --tag files --host files files-backup.db files > /dev/null)
sqlite3 /state/files.db "CREATE TABLE uploads (id TEXT PRIMARY KEY); INSERT INTO uploads VALUES ('LIVELIVELIVELIVELIVELI');"
mkdir /state/files
echo 'a live upload' > /state/files/LIVELIVELIVELIVELIVELI
dd if=/dev/zero of=/state/filler bs=1k count=700 2> /dev/null
status=0
/bin/sh /opt/files-backup/backup.sh restore > /dev/null 2> /tmp/err || status=$?
echo "status $status"
cat /tmp/err
ls -A /state /state/files
sqlite3 /state/files.db 'SELECT id FROM uploads'
EOF

  diff - "$tree/out" << 'EOF'
status 1
cp: write error: No space left on device
cannot stage files.db in /state
/state:
.files-backup.lock
files
files.db
filler

/state/files:
LIVELIVELIVELIVELIVELI
LIVELIVELIVELIVELIVELI
EOF
}

it_lists_the_snapshots_in_ls_mode() {
  local image="$1" script="$2" status=0
  name="files-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" << 'EOF'
restic init > /dev/null
mkdir -p /tmp/snap/files
sqlite3 /tmp/snap/files-backup.db 'CREATE TABLE uploads (id TEXT PRIMARY KEY);'
(cd /tmp/snap && restic backup --tag files --host files --time '2020-01-02 03:04:05' files-backup.db files > /dev/null)
EOF

  run_backup "$name" "$image" --entrypoint /bin/sh \
    -v "$script:/opt/files-backup/backup.sh:ro" /opt/files-backup/backup.sh ls \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
ID        Time                 Host        Tags        Paths                      Size
--------------------------------------------------------------------------------------------
ID  2020-01-02 03:04:05  files       files       /tmp/snap/files            SIZE
                                                       /tmp/snap/files-backup.db
--------------------------------------------------------------------------------------------
1 snapshots
EOF
  assert_status 0 "$status"
}

it_prints_the_usage_for_an_unknown_mode() {
  local image="$1" script="$2" status=0
  name="files-backup-$3-$BASHPID"
  create_case_tree 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true'
  setup_test "$tree" "$name" "$image"

  run_backup "$name" "$image" --entrypoint /bin/sh \
    -v "$script:/opt/files-backup/backup.sh:ro" /opt/files-backup/backup.sh prune \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: files-backup backup|restore|ls'
  assert_status 2 "$status"
}

# Boot data every case needs: a seed directory the backup shell reads at /seed, and a state volume
# and a restic repository volume owned by the service's uid, as fsGroup 65532 leaves the pod's
# volume. Its chown container is named for the case's trap.
setup_test() {
  local tree="$1" name="$2" image="$3"
  mkdir "$tree/seed"
  chmod -R a+rwX "$tree/seed"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh \
    -v "$name-state:/s" -v "$name-repo:/r" "$image" -c 'chown 65532:65532 /s /r'
}

# Boot data every case needs: the backup image the stack config pins for the gateway, nixie and the
# files service (atcGateway.backupImage), pulled once unless BACKUP_IMAGE names a local build, and
# the script under test, by absolute path for the bind mount.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [ -n "${BACKUP_IMAGE:-}" ]; then
  image="$BACKUP_IMAGE"
else
  image="$(cd "$repo" && bun -e 'console.log(Bun.YAML.parse(await Bun.file("infra/Pulumi.prod.yaml").text()).config["geoff-cloud:atcGateway"].backupImage)')"
  docker pull -q "$image" > /dev/null
fi
run="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
run_cases "$image" "$repo/deploy/files/backup/backup.sh" "$run"
