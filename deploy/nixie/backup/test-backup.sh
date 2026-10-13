#!/usr/bin/env bash
# Fixture test for nixie's backup script (backup.sh), run locally with Docker in the backup image
# that the stack config pins as nixie.backupImage. It touches no cluster and no cloud account.
#
# It runs the script as the backup CronJob and the restore Job run it
# (infra/build-nixie-backup-pod-spec.ts, deploy/nixie/restore-job.yaml): nixie's uid and gid
# 10001, the script mounted read-only and run by /bin/sh in place of the image's entrypoint, the
# state volume at /state and a local restic repository at /repo. What this proves: a backup takes
# nixie.db and keys.db alone, with the rows still in a live writer's WAL, and copies again when
# nixie writes keys.db during the copies, so a snapshot holds no active item without its key; it
# stops before restic on a missing database, a failed nixie.db copy or a copy that fails the
# integrity check; retention prunes nixie's snapshots and leaves another tool's
# alone; a restore checks both databases before it replaces them and their WAL files; and ls,
# SNAPSHOT and the usage. What it does not prove: R2, k3s, and nixie starting on a restored volume,
# which the restore test in docs/runbooks/nixie-backup.md covers.
#
# `bun run test:nixie-backup-fixture` runs it; one case alone:
#
#   CASE='ls mode' bash deploy/nixie/backup/test-backup.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/test-lib/run-backup.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/test-lib/run-backup-shell.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/test-lib/normalize-restic-output.sh"

it_backs_up_nixie_db_and_keys_db_alone() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
sqlite3 /state/nixie.db "CREATE TABLE records (v); INSERT INTO records VALUES ('a record');"
sqlite3 /state/keys.db "CREATE TABLE record_keys (key_id TEXT PRIMARY KEY, wrapped BLOB); INSERT INTO record_keys VALUES ('a key', x'00');"
sqlite3 /state/nixie-schema-6.db 'CREATE TABLE old (v);'
mkdir /state/run && echo socket > /state/run/control.sock
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh backup \
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
Dirs:            0 new,     0 changed,     0 unmodified
Added to the repository: SIZE (SIZE stored)

processed 2 files, SIZE in T
snapshot ID saved
Applying Policy: keep 7 daily, 4 weekly snapshots
keep 1 snapshots:
ID        Time                 Host        Tags        Reasons          Paths              Size
-----------------------------------------------------------------------------------------------------
ID  NOW  nixie       nixie       daily snapshot   /tmp/nixie-backup  SIZE
                                                       weekly snapshot
-----------------------------------------------------------------------------------------------------
1 snapshots

EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 > "$tree/snapshot" << 'EOF'
restic ls --tag nixie --host nixie latest | tail -n +2
restic dump latest /nixie.db > /tmp/nixie.db && sqlite3 /tmp/nixie.db 'SELECT v FROM records'
restic dump latest /keys.db > /tmp/keys.db && sqlite3 /tmp/keys.db 'SELECT key_id FROM record_keys'
EOF
  diff - "$tree/snapshot" << 'EOF'
/keys.db
/nixie.db
a record
a key
EOF
}

# A writer holds nixie.db open in WAL mode, as nixie does, and its last row is still in the WAL
# when the backup runs. The backup runs inside the same container as the writer, so the writer
# stays open; the case reads the row back from the snapshot.
it_backs_up_the_rows_in_a_live_writers_wal() {
  local image="$1" script="$2"
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"

  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -e STATE_DIR=/state \
    -v "$script:/opt/nixie-backup/backup.sh:ro" > "$tree/out" << 'EOF'
sqlite3 /state/keys.db 'CREATE TABLE record_keys (key_id TEXT PRIMARY KEY, wrapped BLOB);'
sqlite3 /state/nixie.db 'PRAGMA journal_mode=WAL; CREATE TABLE records (v);' > /dev/null
{
  echo "INSERT INTO records VALUES ('in the wal');"
  sleep 60
} | sqlite3 /state/nixie.db > /dev/null &
writer=$!
i=0
until [ "$(sqlite3 /state/nixie.db 'SELECT count(*) FROM records' 2> /dev/null)" = 1 ]; do
  i=$((i + 1)); [ "$i" -lt 100 ] || exit 1; sleep 0.1
done
[ -s /state/nixie.db-wal ] && echo "wal before: present"
/bin/sh /opt/nixie-backup/backup.sh backup > /dev/null
kill "$writer"
restic dump latest /nixie.db > /tmp/nixie.db
sqlite3 /tmp/nixie.db 'SELECT v FROM records'
EOF

  diff - "$tree/out" << 'EOF'
wal before: present
in the wal
EOF
}

# The race: nixie creates k1 and its key after the backup reads keys.db's version and before it
# copies nixie.db, then forgets k1 after that copy and before the keys.db copy. Neither keys.db
# copy then holds k1's key, while the first nixie.db copy holds k1 active. The changed version
# makes the backup copy again, and the snapshot holds k1 forgetting without its key.
it_copies_again_when_nixie_creates_and_forgets_an_item_during_the_copies() {
  local image="$1" script="$2"
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  write_nixie_steps_wrapper "$tree/seed/bin/sqlite3"

  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -e STATE_DIR=/state \
    -v "$script:/opt/nixie-backup/backup.sh:ro" > "$tree/out" << 'EOF'
sqlite3 /state/nixie.db "PRAGMA journal_mode=WAL; CREATE TABLE items (id, state);" > /dev/null
sqlite3 /state/keys.db "PRAGMA journal_mode=WAL; CREATE TABLE record_keys (key_id TEXT PRIMARY KEY, wrapped BLOB);" > /dev/null
printf 'create k1 forget k1\n' > /tmp/steps
PATH="/seed/bin:$PATH" /bin/sh /opt/nixie-backup/backup.sh backup > /tmp/backup.out
grep '^nixie wrote' /tmp/backup.out || true
restic dump latest /nixie.db > /tmp/nixie.db
restic dump latest /keys.db > /tmp/keys.db
sqlite3 /tmp/nixie.db "SELECT id || ' ' || state FROM items ORDER BY id"
sqlite3 /tmp/keys.db 'SELECT key_id FROM record_keys ORDER BY key_id'
sqlite3 /tmp/nixie.db "ATTACH '/tmp/keys.db' AS keys;
  SELECT 'active without its key: ' || count(*) FROM items
  WHERE state = 'active' AND id NOT IN (SELECT key_id FROM keys.record_keys)"
EOF

  diff - "$tree/out" << 'EOF'
nixie wrote keys.db during the copy; copying again
k1 forgetting
active without its key: 0
EOF
}

# nixie forgets k1, an item older than the backup, between the copies: the first pair holds k1
# active without its key, so the backup copies again, and the second pair holds k1 forgetting
# without its key and k2 with its key.
it_copies_again_when_nixie_removes_a_record_key_between_the_copies() {
  local image="$1" script="$2"
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  write_nixie_steps_wrapper "$tree/seed/bin/sqlite3"

  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -e STATE_DIR=/state \
    -v "$script:/opt/nixie-backup/backup.sh:ro" > "$tree/out" << 'EOF'
sqlite3 /state/nixie.db "PRAGMA journal_mode=WAL; CREATE TABLE items (id, state);" > /dev/null
sqlite3 /state/keys.db "PRAGMA journal_mode=WAL; CREATE TABLE record_keys (key_id TEXT PRIMARY KEY, wrapped BLOB);" > /dev/null
sqlite3 /state/nixie.db "INSERT INTO items VALUES ('k1', 'active'), ('k2', 'active');"
sqlite3 /state/keys.db "INSERT INTO record_keys VALUES ('k1', x'01'), ('k2', x'02');"
printf 'forget k1\n' > /tmp/steps
PATH="/seed/bin:$PATH" /bin/sh /opt/nixie-backup/backup.sh backup > /tmp/backup.out
grep '^nixie wrote' /tmp/backup.out || true
restic dump latest /nixie.db > /tmp/nixie.db
restic dump latest /keys.db > /tmp/keys.db
sqlite3 /tmp/nixie.db "SELECT id || ' ' || state FROM items ORDER BY id"
sqlite3 /tmp/keys.db 'SELECT key_id FROM record_keys ORDER BY key_id'
sqlite3 /tmp/nixie.db "ATTACH '/tmp/keys.db' AS keys;
  SELECT 'active without its key: ' || count(*) FROM items
  WHERE state = 'active' AND id NOT IN (SELECT key_id FROM keys.record_keys)"
EOF

  diff - "$tree/out" << 'EOF'
nixie wrote keys.db during the copy; copying again
k1 forgetting
k2 active
k2
active without its key: 0
EOF
}
it_fails_a_backup_when_nixie_writes_keys_db_during_every_copy() {
  local image="$1" script="$2"
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  write_nixie_steps_wrapper "$tree/seed/bin/sqlite3"

  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -e STATE_DIR=/state \
    -v "$script:/opt/nixie-backup/backup.sh:ro" > "$tree/out" << 'EOF'
sqlite3 /state/nixie.db "PRAGMA journal_mode=WAL; CREATE TABLE items (id, state);" > /dev/null
sqlite3 /state/keys.db "PRAGMA journal_mode=WAL; CREATE TABLE record_keys (key_id TEXT PRIMARY KEY, wrapped BLOB);" > /dev/null
printf 'create k1\ncreate k2\ncreate k3\ncreate k4\ncreate k5\n' > /tmp/steps
PATH="/seed/bin:$PATH" /bin/sh /opt/nixie-backup/backup.sh backup 2>&1 | grep -v 'restic\|repository\|password\|irrecoverably\|^$' || true
restic snapshots --json
EOF

  diff - "$tree/out" << 'EOF'
nixie wrote keys.db during the copy; copying again
nixie wrote keys.db during the copy; copying again
nixie wrote keys.db during the copy; copying again
nixie wrote keys.db during the copy; copying again
nixie wrote keys.db during each of 5 copies
[]
EOF
}

# sqlite3 ignores the exit status of a .system command, so the backup itself checks that the
# nixie.db copy succeeded.
it_fails_a_backup_whose_nixie_db_copy_fails_before_restic() {
  local image="$1" script="$2"
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  write_nixie_steps_wrapper "$tree/seed/bin/sqlite3"

  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 -e STATE_DIR=/state \
    -v "$script:/opt/nixie-backup/backup.sh:ro" > "$tree/out" << 'EOF'
sqlite3 /state/nixie.db "PRAGMA journal_mode=WAL; CREATE TABLE items (id, state);" > /dev/null
sqlite3 /state/keys.db "PRAGMA journal_mode=WAL; CREATE TABLE record_keys (key_id TEXT PRIMARY KEY, wrapped BLOB);" > /dev/null
printf 'fail\n' > /tmp/steps
status=0
PATH="/seed/bin:$PATH" /bin/sh /opt/nixie-backup/backup.sh backup > /tmp/backup.out 2> /tmp/backup.err || status=$?
echo "exit $status"
grep -v '^created restic\|^Please note\|^the repository\|^irrecoverably\|^$' /tmp/backup.out || true
cat /tmp/backup.err
restic snapshots --json
EOF

  diff - "$tree/out" << 'EOF'
exit 1
System command returns 256
the copy of nixie.db failed
[]
EOF
}

it_fails_a_backup_without_keys_db_before_restic() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 <<< \
    "sqlite3 /state/nixie.db 'CREATE TABLE records (v);'"

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh backup \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'no keys.db in /state'
  diff /dev/null "$tree/out"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 <<< 'ls -A /state /repo' > "$tree/left"
  diff - "$tree/left" << 'EOF'
/repo:

/state:
nixie.db
EOF
}

# keys.db's index holds a key its table does not (row0010 rewritten as row0019), so sqlite3
# .backup copies its pages whole and only the integrity check on the copy fails.
it_fails_a_backup_whose_copy_fails_the_integrity_check() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  python3 - "$tree/seed/keys.db" << 'EOF'
import sqlite3, sys
path = sys.argv[1]
db = sqlite3.connect(path)
db.execute("PRAGMA page_size=4096")
db.execute("CREATE TABLE t (x TEXT)")
db.execute("CREATE INDEX t_x ON t (x)")
db.executemany("INSERT INTO t VALUES (?)", [("row%04d" % i,) for i in range(50)])
db.commit()
db.close()
data = bytearray(open(path, "rb").read())
index_key = data.rindex(b"row0010")
data[index_key + 6] = ord("9")
open(path, "wb").write(data)
EOF
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
sqlite3 /state/nixie.db 'CREATE TABLE records (v);'
cp /seed/keys.db /state/keys.db
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh backup \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the copy of keys.db failed the integrity check'
  diff /dev/null "$tree/out"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 <<< 'restic snapshots --json' > "$tree/snapshots"
  diff - "$tree/snapshots" <<< '[]'
}

# Three nixie snapshots from earlier runs, each from its own path, all on one fixed day, and one
# other tool's snapshot older than all of them: grouped by host and tags, retention keeps the
# newest of that day (old-c) and the group's oldest (old-a) and forgets old-b; the other tool's
# snapshot stays.
it_prunes_nixies_snapshots_and_leaves_another_tools_alone() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
for s in a:10 b:11 c:12; do
  d="/tmp/old-${s%%:*}"
  mkdir -p "$d" && echo old > "$d/nixie.db"
  (cd "$d" && restic backup -q --tag nixie --host nixie --time "2020-01-06 ${s#*:}:00:00" .)
done
mkdir -p /tmp/other && echo other > /tmp/other/f
(cd /tmp/other && restic backup -q --tag other --host other --time "2020-01-06 09:00:00" .)
sqlite3 /state/nixie.db 'CREATE TABLE records (v);'
sqlite3 /state/keys.db 'CREATE TABLE record_keys (key_id TEXT PRIMARY KEY, wrapped BLOB);'
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh backup \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
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

# The restore replaces both databases, removes their stale WAL and SHM files, leaves every other
# file, and leaves the restored files owned by nixie's uid.
it_restores_both_databases_and_removes_their_stale_wal_and_shm_files() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
mkdir /tmp/snap
sqlite3 /tmp/snap/nixie.db "CREATE TABLE records (v); INSERT INTO records VALUES ('restored record');"
sqlite3 /tmp/snap/keys.db "CREATE TABLE record_keys (v); INSERT INTO record_keys VALUES ('restored key');"
(cd /tmp/snap && restic backup -q --tag nixie --host nixie --time "2020-01-06 10:00:00" .)
for f in nixie.db keys.db; do
  echo stale > "/state/$f"; echo stale > "/state/$f-wal"; echo stale > "/state/$f-shm"
done
echo kept > /state/nixie-schema-6.db
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh restore \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @nixie to /tmp/tmp.X
Summary: Restored 2 files/dirs (SIZE) in T
restored nixie.db: integrity_check ok
restored keys.db: integrity_check ok
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 > "$tree/state" << 'EOF'
cd /state && stat -c '%n %u:%g' * | sort
sqlite3 /state/nixie.db 'SELECT v FROM records'
sqlite3 /state/keys.db 'SELECT v FROM record_keys'
EOF
  diff - "$tree/state" << 'EOF'
keys.db 10001:10001
nixie-schema-6.db 10001:10001
nixie.db 10001:10001
restored record
restored key
EOF
}

it_fails_a_restore_of_a_snapshot_without_keys_db_and_keeps_the_state() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
mkdir /tmp/snap
sqlite3 /tmp/snap/nixie.db "CREATE TABLE records (v); INSERT INTO records VALUES ('from the snapshot');"
(cd /tmp/snap && restic backup -q --tag nixie --host nixie --time "2020-01-06 10:00:00" .)
sqlite3 /state/nixie.db "CREATE TABLE records (v); INSERT INTO records VALUES ('current');"
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh restore \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the snapshot holds no keys.db'
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @nixie to /tmp/tmp.X
Summary: Restored 1 files/dirs (SIZE) in T
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 <<< \
    "sqlite3 /state/nixie.db 'SELECT v FROM records'" > "$tree/state"
  diff - "$tree/state" <<< current
}

# The snapshot's keys.db carries the index corruption that the backup case uses; nixie.db is
# sound, and the restore replaces neither.
it_fails_a_restore_whose_snapshot_fails_the_integrity_check_and_keeps_the_state() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  python3 - "$tree/seed/keys.db" << 'EOF'
import sqlite3, sys
path = sys.argv[1]
db = sqlite3.connect(path)
db.execute("PRAGMA page_size=4096")
db.execute("CREATE TABLE t (x TEXT)")
db.execute("CREATE INDEX t_x ON t (x)")
db.executemany("INSERT INTO t VALUES (?)", [("row%04d" % i,) for i in range(50)])
db.commit()
db.close()
data = bytearray(open(path, "rb").read())
index_key = data.rindex(b"row0010")
data[index_key + 6] = ord("9")
open(path, "wb").write(data)
EOF
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
mkdir /tmp/snap
sqlite3 /tmp/snap/nixie.db "CREATE TABLE records (v); INSERT INTO records VALUES ('from the snapshot');"
cp /seed/keys.db /tmp/snap/keys.db
(cd /tmp/snap && restic backup -q --tag nixie --host nixie --time "2020-01-06 10:00:00" .)
sqlite3 /state/nixie.db "CREATE TABLE records (v); INSERT INTO records VALUES ('current');"
sqlite3 /state/keys.db "CREATE TABLE record_keys (v); INSERT INTO record_keys VALUES ('current key');"
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh restore \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the restored keys.db failed the integrity check'
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @nixie to /tmp/tmp.X
Summary: Restored 2 files/dirs (SIZE) in T
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 > "$tree/state" << 'EOF'
sqlite3 /state/nixie.db 'SELECT v FROM records'
sqlite3 /state/keys.db 'SELECT v FROM record_keys'
EOF
  diff - "$tree/state" << 'EOF'
current
current key
EOF
}

# The state directory refuses new files, as a full volume would, so staging the first copy fails
# and the restore stops before it deletes or replaces either current database.
it_fails_a_restore_that_cannot_stage_its_copies_and_keeps_the_state() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
mkdir /tmp/snap
sqlite3 /tmp/snap/nixie.db "CREATE TABLE records (v); INSERT INTO records VALUES ('from the snapshot');"
sqlite3 /tmp/snap/keys.db "CREATE TABLE record_keys (v); INSERT INTO record_keys VALUES ('snapshot key');"
(cd /tmp/snap && restic backup -q --tag nixie --host nixie --time "2020-01-06 10:00:00" .)
sqlite3 /state/nixie.db "CREATE TABLE records (v); INSERT INTO records VALUES ('current');"
sqlite3 /state/keys.db "CREATE TABLE record_keys (v); INSERT INTO record_keys VALUES ('current key');"
echo current-wal > /state/nixie.db-wal
chmod 0555 /state
EOF

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh restore \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << 'EOF'
cp: can't create '/state/nixie.db.restoring': Permission denied
cannot stage nixie.db in /state
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 > "$tree/state" << 'EOF'
ls -A /state
cat /state/nixie.db-wal
sqlite3 -readonly /state/keys.db 'SELECT v FROM record_keys'
EOF
  diff - "$tree/state" << 'EOF'
keys.db
nixie.db
nixie.db-wal
current-wal
current key
EOF
}

it_restores_the_snapshot_that_SNAPSHOT_names_instead_of_the_latest() {
  local image="$1" script="$2" older status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
mkdir /tmp/snap
sqlite3 /tmp/snap/nixie.db "CREATE TABLE records (v); INSERT INTO records VALUES ('older');"
sqlite3 /tmp/snap/keys.db 'CREATE TABLE record_keys (v);'
(cd /tmp/snap && restic backup -q --tag nixie --host nixie --time "2020-01-06 10:00:00" .)
sqlite3 /tmp/snap/nixie.db "UPDATE records SET v = 'newer';"
(cd /tmp/snap && restic backup -q --tag nixie --host nixie --time "2020-01-07 10:00:00" .)
EOF
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 <<< 'restic snapshots --json' > "$tree/snapshots"
  older="$(jq -r '.[] | select(.time == "2020-01-06T10:00:00Z") | .short_id' "$tree/snapshots")"
  [ -n "$older" ] || {
    echo "no snapshot from 2020-01-06" >&2
    exit 1
  }

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh -e "SNAPSHOT=$older" \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh restore \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 <<< \
    "sqlite3 /state/nixie.db 'SELECT v FROM records'" > "$tree/value"
  diff - "$tree/value" <<< older
}

# ls lists nixie's snapshots alone; each ID is random, so the case masks that column
it_lists_nixies_snapshots_alone_in_ls_mode() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"
  run_backup_shell "$name" "$image" "$tree" --user 10001:10001 << 'EOF'
restic init -q
mkdir /tmp/a /tmp/other && echo a > /tmp/a/nixie.db && echo other > /tmp/other/f
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
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_rejects_an_unknown_mode_with_its_usage() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_test "$tree" "$name" "$image"

  run_backup "$name" "$image" --user 10001:10001 --entrypoint /bin/sh \
    -v "$script:/opt/nixie-backup/backup.sh:ro" /opt/nixie-backup/backup.sh prune \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: nixie-backup backup|restore|ls'
  diff /dev/null "$tree/out"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

# A sqlite3 wrapper at <path>, which the nixie.db copy cases put first on PATH. Around each copy
# of the live nixie.db it runs the next line of /tmp/steps in nixie's order: `create <id>` commits
# the item's key and then the active item before the copy, `forget <id>` commits the item's
# forgetting state and then removes its key after the copy, and `fail` fails the copy. A line can
# hold both, create first. Every other call goes to the real sqlite3.
write_nixie_steps_wrapper() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" << 'EOF'
#!/bin/sh
real=$(PATH="${PATH#/seed/bin:}" command -v sqlite3)
case "$1 $2" in
  "/state/nixie.db .backup "*) ;;
  *) exec "$real" "$@" ;;
esac
step=$(head -n 1 /tmp/steps)
sed -i 1d /tmp/steps
created='' forgotten=''
case "$step" in "create "*) created=${step#create } && created=${created%% *} ;; esac
case "$step" in *"forget "*) forgotten=${step##*forget } ;; esac
[ "$step" = fail ] && exit 1
if [ -n "$created" ]; then
  "$real" /state/keys.db "INSERT INTO record_keys VALUES ('$created', x'00')"
  "$real" /state/nixie.db "INSERT INTO items VALUES ('$created', 'active')"
fi
"$real" "$@" || exit
if [ -n "$forgotten" ]; then
  "$real" /state/nixie.db "UPDATE items SET state = 'forgetting' WHERE id = '$forgotten'"
  "$real" /state/keys.db "DELETE FROM record_keys WHERE key_id = '$forgotten'"
fi
EOF
  chmod -R a+rX "$(dirname "$path")"
  chmod a+x "$path"
}

# Boot data every case needs: a seed directory the backup shell reads at /seed, and a state
# volume and a restic repository volume owned by nixie's uid, as fsGroup 10001 leaves the pod's
# volume. Its chown container is named for the case's trap.
setup_test() {
  local tree="$1" name="$2" image="$3"
  mkdir "$tree/seed"
  chmod -R a+rwX "$tree/seed"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh \
    -v "$name-state:/s" -v "$name-repo:/r" "$image" -c 'chown 10001:10001 /s /r'
}

# Boot data every case needs: the backup image the stack config pins for nixie, pulled once, and
# the script under test, by absolute path for the bind mount.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
image="$(cd "$repo" && bun -e 'console.log(Bun.YAML.parse(await Bun.file("infra/Pulumi.prod.yaml").text()).config["geoff-cloud:nixie"].backupImage)')"
docker pull -q "$image" > /dev/null
run="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
run_cases "$image" "$repo/deploy/nixie/backup/backup.sh" "$run"
