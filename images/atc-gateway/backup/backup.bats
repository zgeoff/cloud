#!/usr/bin/env bats
# bats file_tags=suite:atc-gateway-fixture
# Fixture test for the backup script (backup.sh) in the backup image, run locally with
# Docker. It touches no cluster and no cloud account.
#
# It runs the backup image as the backup CronJob and the restore Job run it
# (infra/cluster/build-atc-gateway-backup-pod-spec.ts, images/atc-gateway/restore-job.yaml).
# What this proves: a backup's retention groups the gateway's snapshots across source paths and
# leaves other snapshots alone; and each declared path of the script (usage, a missing
# STATE_DIR, no databases, an integrity failure on backup and on restore, a snapshot
# without databases, ls, SNAPSHOT, stale WAL files). What it does not prove: R2, k3s. The
# whole backup, wipe and restore of a running gateway is the journey in
# scripts/e2e/journey-atc-gateway-restore.bats.
#
# The images come from scripts/src/test-utils/shell/with-fixture-images.sh, which builds them once
# per run under tags carrying a random per-run id, removes them after, and sets
# FIXTURE_RUN, FIXTURE_GATEWAY_IMAGE and FIXTURE_BACKUP_IMAGE. Each case runs its own
# containers on its own volumes, all named from that id, and removes them when it ends.
# `bun run test:atc-gateway-fixture` runs it after the helper tests; alone:
#
#   bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture
#   CASE='ls mode' bash scripts/src/test-utils/shell/with-fixture-images.sh bash scripts/run-bats.sh atc-gateway-fixture

# a case runs a chown container and then the backup image, and some run restic several times
export BATS_TEST_TIMEOUT=180

setup_file() {
  load '../../../scripts/src/test-utils/bats/setup'
  : "${FIXTURE_RUN:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
  : "${FIXTURE_GATEWAY_IMAGE:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
  : "${FIXTURE_BACKUP_IMAGE:?is unset: run this under scripts/src/test-utils/shell/with-fixture-images.sh}"
}

setup() {
  load '../../../scripts/src/test-utils/bats/setup'
  load '../../../scripts/src/test-utils/shell/run-backup.sh'
  load '../../../scripts/src/test-utils/shell/run-backup-shell.sh'
  load '../../../scripts/src/test-utils/shell/normalize-restic-output.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  name="atc-gw-backup-script-$FIXTURE_RUN-$BATS_SUITE_TEST_NUMBER"
  repo="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # sets RESTIC_IMAGE, among the pins
  # shellcheck source=/dev/null
  source "$repo/images/atc-gateway/versions.env"
  # shellcheck disable=SC2153 # RESTIC_IMAGE comes from versions.env
  restic_image="$RESTIC_IMAGE"
}

teardown() {
  stop_timeout_watchdog
  docker rm -f "$name-backup" "$name-shell" "$name-setup" > /dev/null 2>&1 || true
  docker volume rm -f "$name-state" "$name-repo" > /dev/null || true
}

# Boot data every case needs: a seed directory the backup shell reads at /seed, and a
# state volume and a restic repository volume owned by the nonroot uid, as fsGroup 65532
# leaves the pod's new volume. The pinned restic image does the chown.
setup_test() {
  local tree="$1" name="$2" restic_image="$3"
  mkdir "$tree/seed"
  chmod -R a+rwX "$tree/seed"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh -v "$name-state:/s" -v "$name-repo:/r" "$restic_image" -c 'chown 65532:65532 /s /r'
}

# Three gateway snapshots from older images, each from its own per-run temp path, all on
# one fixed day: grouped by host and tags, retention keeps the newest of that day (old-c)
# and the group's oldest (old-a, kept while keep-daily is not used up) and forgets old-b.
# Grouped by path, as restic does by default, each would keep itself. The new snapshot's
# time comes from the wall clock, so the case bounds it by clock reads before and after
# the backup, then masks it.
@test "it groups the gateway snapshots across source paths when a backup prunes" {
  local before after new_time
  setup_test "$tree" "$name" "$restic_image"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" << 'EOF'
restic init -q
for s in a:10 b:11 c:12; do
  d="/tmp/old-${s%%:*}"
  mkdir -p "$d" && echo old > "$d/gateway.db"
  (cd "$d" && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 ${s#*:}:00:00" .)
done
sqlite3 /state/gateway.db 'CREATE TABLE fixture (x); INSERT INTO fixture VALUES (1);'
EOF
  before="$(date -u +%s)"

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" backup > "$tree/backup.out" 2> "$tree/backup.err"

  after="$(date -u +%s)"
  diff /dev/null "$tree/backup.err"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'restic snapshots --json' > "$tree/snapshots"
  jq -r '.[] | select(.paths == ["/tmp/atc-gateway-backup"]) | .time | sub("\\.[0-9]+"; "") |
      fromdateiso8601' "$tree/snapshots" > "$tree/new-time"
  new_time="$(cat "$tree/new-time")"
  assert [ "$new_time" -ge "$before" ]
  assert [ "$new_time" -le "$after" ]
  jq -S '[.[] | {paths, tags, hostname,
      time: (if .paths == ["/tmp/atc-gateway-backup"] then "TIME" else .time end)}] |
      sort_by(.paths)' "$tree/snapshots" > "$tree/kept"
  diff - "$tree/kept" << 'EOF'
[
  {
    "hostname": "atc-gateway",
    "paths": [
      "/tmp/atc-gateway-backup"
    ],
    "tags": [
      "atc-gateway"
    ],
    "time": "TIME"
  },
  {
    "hostname": "atc-gateway",
    "paths": [
      "/tmp/old-a"
    ],
    "tags": [
      "atc-gateway"
    ],
    "time": "2020-01-06T10:00:00Z"
  },
  {
    "hostname": "atc-gateway",
    "paths": [
      "/tmp/old-c"
    ],
    "tags": [
      "atc-gateway"
    ],
    "time": "2020-01-06T12:00:00Z"
  }
]
EOF
  normalize_restic_output < "$tree/backup.out" > "$tree/backup.normal"
  diff - "$tree/backup.normal" << 'EOF'
no parent snapshot found, will read all files

Files:           1 new,     0 changed,     0 unmodified
Dirs:            0 new,     0 changed,     0 unmodified
Added to the repository: SIZE (SIZE stored)

processed 1 files, SIZE in T
snapshot ID saved
Applying Policy: keep 7 daily, 4 weekly snapshots
keep 3 snapshots:
ID        Time                 Host         Tags         Reasons                 Paths                    Size
-------------------------------------------------------------------------------------------------------------------
ID  2020-01-06 10:00:00  atc-gateway  atc-gateway  oldest daily snapshot   /tmp/old-a               SIZE
                                                         oldest weekly snapshot
ID  2020-01-06 12:00:00  atc-gateway  atc-gateway  daily snapshot          /tmp/old-c               SIZE
                                                         weekly snapshot
ID  NOW  atc-gateway  atc-gateway  daily snapshot          /tmp/atc-gateway-backup  SIZE
                                                         weekly snapshot
-------------------------------------------------------------------------------------------------------------------
3 snapshots

remove 1 snapshots:
ID        Time                 Host         Tags         Paths       Size
-------------------------------------------------------------------------
ID  2020-01-06 11:00:00  atc-gateway  atc-gateway  /tmp/old-b  SIZE
-------------------------------------------------------------------------
1 snapshots

[T] 100.00%  1 / 1 files deleted
1 snapshots have been removed, running prune
loading indexes...
loading all snapshots...
finding data that is still in use for 3 snapshots
[T] 100.00%  3 / 3 snapshots
searching used packs...
collecting packs for deletion and repacking
[T] 100.00%  6 / 6 packs processed

to repack:             0 blobs / SIZE
this removes:          0 blobs / SIZE
to delete:             1 blobs / SIZE
total prune:           1 blobs / SIZE
remaining:             5 blobs / SIZE
unused size after prune: SIZE (0.00% of remaining size)

rebuilding index
[T] 100.00%  4 / 4 indexes processed
[T] 100.00%  4 / 4 old indexes deleted
removing 1 old packs
[T] 100.00%  1 / 1 files deleted
done
EOF
}

# The other tool's snapshot is older than every gateway snapshot and on the same fixed
# day, so it would be forgotten if retention did not filter by the gateway's host and tag.
@test "it leaves another tools snapshot alone when a backup prunes" {
  setup_test "$tree" "$name" "$restic_image"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" << 'EOF'
restic init -q
for s in a:10 b:11; do
  d="/tmp/old-${s%%:*}"
  mkdir -p "$d" && echo old > "$d/gateway.db"
  (cd "$d" && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 ${s#*:}:00:00" .)
done
mkdir -p /tmp/other && echo other > /tmp/other/f
(cd /tmp/other && restic backup -q --tag other --host other --time "2020-01-06 09:00:00" .)
sqlite3 /state/gateway.db 'CREATE TABLE fixture (x); INSERT INTO fixture VALUES (1);'
EOF
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'restic snapshots --json --tag other' > "$tree/other-before"
  jq -e 'length == 1' "$tree/other-before" > /dev/null

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" backup > "$tree/backup.out" 2> "$tree/backup.err"

  diff /dev/null "$tree/backup.err"
  normalize_restic_output < "$tree/backup.out" > "$tree/backup.normal"
  diff - "$tree/backup.normal" << 'EOF'
no parent snapshot found, will read all files

Files:           1 new,     0 changed,     0 unmodified
Dirs:            0 new,     0 changed,     0 unmodified
Added to the repository: SIZE (SIZE stored)

processed 1 files, SIZE in T
snapshot ID saved
Applying Policy: keep 7 daily, 4 weekly snapshots
keep 3 snapshots:
ID        Time                 Host         Tags         Reasons                 Paths                    Size
-------------------------------------------------------------------------------------------------------------------
ID  2020-01-06 10:00:00  atc-gateway  atc-gateway  oldest daily snapshot   /tmp/old-a               SIZE
                                                         oldest weekly snapshot
ID  2020-01-06 11:00:00  atc-gateway  atc-gateway  daily snapshot          /tmp/old-b               SIZE
                                                         weekly snapshot
ID  NOW  atc-gateway  atc-gateway  daily snapshot          /tmp/atc-gateway-backup  SIZE
                                                         weekly snapshot
-------------------------------------------------------------------------------------------------------------------
3 snapshots

EOF
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'restic snapshots --json --tag other' > "$tree/other-after"
  jq -S . "$tree/other-before" > "$tree/other-before.json"
  jq -S . "$tree/other-after" > "$tree/other-after.json"
  diff "$tree/other-before.json" "$tree/other-after.json"
}

@test "it rejects a run without a mode with its usage" {
  local status=0
  setup_test "$tree" "$name" "$restic_image"

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 2

  diff - "$tree/err" <<< 'usage: atc-gateway-backup backup|restore|ls'
  diff /dev/null "$tree/out"
}

@test "it rejects an unknown mode with its usage" {
  local status=0
  setup_test "$tree" "$name" "$restic_image"

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" prune > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 2

  diff - "$tree/err" <<< 'usage: atc-gateway-backup backup|restore|ls'
  diff /dev/null "$tree/out"
}

@test "it stops before restic when STATE DIR is unset" {
  local status=0
  setup_test "$tree" "$name" "$restic_image"

  docker run --rm --name "$name-backup" --user 65532:65532 --security-opt no-new-privileges \
    --cap-drop ALL -e HOME=/tmp --tmpfs /tmp -v "$name-repo:/repo" -e RESTIC_REPOSITORY=/repo \
    -e RESTIC_PASSWORD=fixture-only "$FIXTURE_BACKUP_IMAGE" backup > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 2

  diff - "$tree/err" <<< '/usr/local/bin/atc-gateway-backup: line 14: STATE_DIR: set STATE_DIR'
  diff /dev/null "$tree/out"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'ls -A /repo' > "$tree/repo"
  diff /dev/null "$tree/repo"
}

@test "it fails a backup of a state dir without databases" {
  local status=0
  setup_test "$tree" "$name" "$restic_image"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'restic init -q; echo notes > /state/readme'

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" backup > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  diff - "$tree/err" <<< 'no databases in /state'
  diff /dev/null "$tree/out"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'restic snapshots --json' > "$tree/snapshots"
  diff - "$tree/snapshots" <<< '[]'
}

# The database's index holds a key its table does not (row0010 rewritten as row0019), so
# sqlite3 .backup copies its pages whole and only the integrity check on the copy fails.
# The backup script pipes that check into `grep -qx ok`, so it fails without a message.
# Its work copies live in the container's /tmp, which goes when the container exits, so
# the case runs the entrypoint inside the backup shell (the same image, uid, security and
# volumes, with STATE_DIR set as the pod sets it) and reads the work directory there: the
# databases before gateway.db and gateway.db itself are copied, the one after it is not,
# and the copy of gateway.db fails sqlite's integrity check. That places the stop at the
# check, not at the copy or at restic.
@test "it fails a backup whose copy fails the integrity check" {
  setup_test "$tree" "$name" "$restic_image"
  python3 - "$tree/seed/gateway.db" << 'EOF'
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
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" << 'EOF'
restic init -q
cp /seed/gateway.db /state/gateway.db
sqlite3 /state/a.db 'CREATE TABLE a (x); INSERT INTO a VALUES (1);'
sqlite3 /state/zz.db 'CREATE TABLE z (x); INSERT INTO z VALUES (1);'
EOF

  mkdir "$tree/seen"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" > "$tree/seen.tar" << 'EOF'
mkdir /tmp/seen
status=0
STATE_DIR=/state /usr/local/bin/atc-gateway-backup backup < /dev/null > /tmp/seen/out 2> /tmp/seen/err || status=$?
echo "$status" > /tmp/seen/status
ls -A /tmp/atc-gateway-backup > /tmp/seen/work-dir
sqlite3 /tmp/atc-gateway-backup/gateway.db 'PRAGMA integrity_check;' > /tmp/seen/integrity
tar -cf - -C /tmp/seen .
EOF

  tar -xf "$tree/seen.tar" -C "$tree/seen"
  diff /dev/null "$tree/seen/out"
  diff /dev/null "$tree/seen/err"
  diff - "$tree/seen/status" <<< 1
  diff - "$tree/seen/work-dir" << 'EOF'
a.db
gateway.db
EOF
  diff - "$tree/seen/integrity" <<< 'row 11 missing from index t_x'
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'restic snapshots --json' > "$tree/snapshots"
  diff - "$tree/snapshots" <<< '[]'
}

# The same index corruption, inside the latest gateway snapshot: the restore checks each
# database before it replaces anything, so the state keeps the database it had.
@test "it fails a restore whose snapshot fails the integrity check and keeps the state" {
  local status=0
  setup_test "$tree" "$name" "$restic_image"
  python3 - "$tree/seed/gateway.db" << 'EOF'
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
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" << 'EOF'
restic init -q
mkdir /tmp/snap && cp /seed/gateway.db /tmp/snap/gateway.db
(cd /tmp/snap && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
sqlite3 /state/gateway.db "CREATE TABLE f (v); INSERT INTO f VALUES ('current');"
EOF

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" restore > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @atc-gateway to /tmp/tmp.X
Summary: Restored 1 files/dirs (SIZE) in T
EOF
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'ls -A /state' > "$tree/state-files"
  diff - "$tree/state-files" <<< gateway.db
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'sqlite3 /state/gateway.db "SELECT v FROM f"' > "$tree/state-rows"
  diff - "$tree/state-rows" <<< current
}

@test "it fails a restore of a snapshot without databases" {
  local status=0
  setup_test "$tree" "$name" "$restic_image"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" << 'EOF'
restic init -q
mkdir /tmp/snap && echo notes > /tmp/snap/readme
(cd /tmp/snap && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
EOF

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" restore > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  diff - "$tree/err" <<< 'snapshot holds no databases'
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @atc-gateway to /tmp/tmp.X
Summary: Restored 1 files/dirs (SIZE) in T
EOF
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'ls -A /state' > "$tree/state"
  diff /dev/null "$tree/state"
}

@test "it fails a restore when the repository holds no gateway snapshot" {
  local status=0
  setup_test "$tree" "$name" "$restic_image"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" << 'EOF'
restic init -q
mkdir /tmp/other && echo other > /tmp/other/gateway.db
(cd /tmp/other && restic backup -q --tag other --host other --time "2020-01-06 10:00:00" .)
EOF

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" restore > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  diff - "$tree/err" << 'EOF'
Fatal: failed to find snapshot: snapshot filter (Paths:[] Tags:[[atc-gateway]] Hosts:[atc-gateway]): no snapshot found
EOF
  diff /dev/null "$tree/out"
}

# ls lists the gateway's snapshots alone; each ID is random, so the case masks that column
@test "it lists the gateway snapshots alone in ls mode" {
  setup_test "$tree" "$name" "$restic_image"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" << 'EOF'
restic init -q
mkdir /tmp/a /tmp/other && echo a > /tmp/a/gateway.db && echo other > /tmp/other/f
(cd /tmp/a && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
(cd /tmp/a && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-07 10:00:00" .)
(cd /tmp/other && restic backup -q --tag other --host other --time "2020-01-06 09:00:00" .)
EOF

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" ls > "$tree/out" 2> "$tree/err"

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
ID        Time                 Host         Tags         Paths   Size
---------------------------------------------------------------------
ID  2020-01-06 10:00:00  atc-gateway  atc-gateway  /tmp/a  SIZE
ID  2020-01-07 10:00:00  atc-gateway  atc-gateway  /tmp/a  SIZE
---------------------------------------------------------------------
2 snapshots
EOF
}

@test "it restores the snapshot that SNAPSHOT names instead of the latest" {
  local older
  setup_test "$tree" "$name" "$restic_image"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" << 'EOF'
restic init -q
mkdir /tmp/snap
sqlite3 /tmp/snap/gateway.db "CREATE TABLE f (v); INSERT INTO f VALUES ('older');"
(cd /tmp/snap && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
sqlite3 /tmp/snap/gateway.db "UPDATE f SET v = 'newer';"
(cd /tmp/snap && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-07 10:00:00" .)
EOF
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'restic snapshots --json' > "$tree/snapshots"
  older="$(jq -r '.[] | select(.time == "2020-01-06T10:00:00Z") | .short_id' "$tree/snapshots")"
  [ -n "$older" ] || {
    echo "no snapshot from 2020-01-06" >&2
    return 1
  }

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" -e "SNAPSHOT=$older" restore > "$tree/out" 2> "$tree/err"

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @atc-gateway to /tmp/tmp.X
Summary: Restored 1 files/dirs (SIZE) in T
EOF
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'sqlite3 /state/gateway.db "SELECT v FROM f"' > "$tree/value"
  diff - "$tree/value" <<< older
}

@test "it removes stale wal and shm files when it restores a database" {
  setup_test "$tree" "$name" "$restic_image"
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" << 'EOF'
restic init -q
mkdir /tmp/snap
sqlite3 /tmp/snap/gateway.db "CREATE TABLE f (v); INSERT INTO f VALUES ('restored');"
(cd /tmp/snap && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
echo stale > /state/gateway.db
echo stale-wal > /state/gateway.db-wal
echo stale-shm > /state/gateway.db-shm
echo kept > /state/other.db-wal
EOF

  run_backup "$name" "$FIXTURE_BACKUP_IMAGE" restore > "$tree/out" 2> "$tree/err"

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @atc-gateway to /tmp/tmp.X
Summary: Restored 1 files/dirs (SIZE) in T
EOF
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'ls -A /state' > "$tree/state-files"
  diff - "$tree/state-files" << 'EOF'
gateway.db
other.db-wal
EOF
  run_backup_shell "$name" "$FIXTURE_BACKUP_IMAGE" "$tree" <<< 'sqlite3 /state/gateway.db "SELECT v FROM f"' > "$tree/state-rows"
  diff - "$tree/state-rows" <<< restored
}
