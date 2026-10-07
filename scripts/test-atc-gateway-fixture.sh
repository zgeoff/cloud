#!/usr/bin/env bash
# Fixture test for the atc-gateway package, run locally with Docker. It touches no
# cluster, no tailnet and no cloud account.
#
# It runs the pinned atc-gateway release with the flags and the container security the
# Deployment sets (infra/build-atc-gateway-spec.ts), and the backup image as the backup
# CronJob and the restore Job run it (infra/create-atc-gateway-backup-job.ts,
# deploy/atc-gateway/restore-job.yaml). What this proves: the image builds from a checked
# binary, runs as nonroot on a read-only root, answers /healthz, /readyz and the metadata
# only on its public Host, keeps its state on the volume across a restart, and that state
# survives a backup, a wipe and a restore; a backup's retention groups the gateway's
# snapshots across source paths and leaves other snapshots alone; and each declared path
# of the backup script (usage, a missing STATE_DIR, no databases, an integrity failure on
# backup and on restore, a snapshot without databases, ls, SNAPSHOT, stale WAL files).
# What it does not prove: gateway-to-daemon transport (the registry's daemon is a dead
# address), R2, k3s.
#
# The images build once per run, under per-run tags that the run removes. Each case then
# starts its own containers on its own volumes and an ephemeral host port, and removes
# them when it exits.
#
#   bash scripts/test-atc-gateway-fixture.sh
#   CASE='foreign Host' bash scripts/test-atc-gateway-fixture.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/wait-for.sh"

it_answers_the_protected_resource_metadata_on_its_public_Host() {
  local gateway_image="$1" port code
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/.well-known/oauth-protected-resource/mcp")"

  jq -S . "$tree/body" > "$tree/body.json"
  diff - "$tree/body.json" << 'EOF'
{
  "authorization_servers": [
    "https://atc.fixture.invalid"
  ],
  "bearer_methods_supported": [
    "header"
  ],
  "resource": "https://atc.fixture.invalid/mcp",
  "scopes_supported": [
    "read",
    "message",
    "spawn",
    "kill"
  ]
}
EOF
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
}

it_answers_healthz_on_its_public_Host() {
  local gateway_image="$1" port code
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/healthz")"

  [ -f "$tree/body" ] || { echo "curl wrote no body file" >&2; exit 1; }
  diff /dev/null "$tree/body"
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
}

it_answers_readyz_on_its_public_Host() {
  local gateway_image="$1" port code
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$port/readyz")"

  [ -f "$tree/body" ] || { echo "curl wrote no body file" >&2; exit 1; }
  diff /dev/null "$tree/body"
  [ "$code" = 200 ] || { echo "HTTP $code, want 200" >&2; exit 1; }
}

# the kubelet's probe reaches the pod by its IP, so the probe must set Host
it_refuses_healthz_for_a_foreign_Host() {
  local gateway_image="$1" port code
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H 'Host: 10.42.0.9:8414' \
    "http://127.0.0.1:$port/healthz")"

  [ -f "$tree/body" ] || { echo "curl wrote no body file" >&2; exit 1; }
  diff /dev/null "$tree/body"
  [ "$code" = 403 ] || { echo "HTTP $code, want 403" >&2; exit 1; }
}

it_refuses_the_metadata_for_a_foreign_Host() {
  local gateway_image="$1" port code
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"

  code="$(curl -q --noproxy '*' -sS -o "$tree/body" -w '%{http_code}' -H 'Host: 10.42.0.9:8414' \
    "http://127.0.0.1:$port/.well-known/oauth-protected-resource/mcp")"

  [ -f "$tree/body" ] || { echo "curl wrote no body file" >&2; exit 1; }
  diff /dev/null "$tree/body"
  [ "$code" = 403 ] || { echo "HTTP $code, want 403" >&2; exit 1; }
}

it_runs_the_gateway_process_as_the_nonroot_uid() {
  local gateway_image="$1"
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"

  start_gateway "$name" "$tree" "$gateway_image"

  docker top "$name" -eo uid,gid,comm,pid > "$tree/top"
  awk '{ print $1, $2, $3 }' "$tree/top" > "$tree/processes"
  diff - "$tree/processes" << 'EOF'
UID GID COMMAND
65532 65532 atc-gateway
EOF
}

it_keeps_a_stored_client_across_a_restart() {
  local gateway_image="$1" client_id
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  docker exec "$name" /usr/local/bin/atc-gateway clients add fixture-client \
    --redirect-uri https://client.fixture.invalid/callback > "$tree/added"
  client_id="$(sed -n 's/^Added fixture-client\. Its client ID is \([A-Za-z0-9]*\)$/\1/p' "$tree/added")"
  diff - "$tree/added" <<< "Added fixture-client. Its client ID is $client_id"
  [ -n "$client_id" ] || { echo "no client ID in the add output" >&2; exit 1; }

  docker restart "$name" > /dev/null
  wait_for_ready "$name"

  docker exec "$name" /usr/local/bin/atc-gateway clients list > "$tree/clients"
  diff - "$tree/clients" <<< "$client_id  fixture-client  https://client.fixture.invalid/callback"
}

# A backup reads the live databases while the gateway runs; the restore goes into the
# volume after the databases are wiped, and a new container finds the client again. The
# backup and the restore run as their production pods do, so the restored files carry the
# restore's own uid and the modes the gateway gave them, with no chown after it.
it_restores_a_stored_client_after_a_backup_a_wipe_and_a_restore() {
  local gateway_image="$1" backup_image="$2" client_id
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  start_gateway "$name" "$tree" "$gateway_image"
  docker exec "$name" /usr/local/bin/atc-gateway clients add fixture-client \
    --redirect-uri https://client.fixture.invalid/callback > "$tree/added"
  client_id="$(sed -n 's/^Added fixture-client\. Its client ID is \([A-Za-z0-9]*\)$/\1/p' "$tree/added")"
  [ -n "$client_id" ] || { cat "$tree/added"; echo "no client ID in the add output" >&2; exit 1; }
  run_backup "$name" "$backup_image" backup > "$tree/backup.out" 2> "$tree/backup.err"
  docker stop "$name" > /dev/null
  docker rm "$name" > /dev/null
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'rm -f /state/*.db*; ls -A /state' > "$tree/wiped"
  diff /dev/null "$tree/wiped"

  run_backup "$name" "$backup_image" restore > "$tree/restore.out" 2> "$tree/restore.err"
  start_gateway "$name" "$tree" "$gateway_image"

  diff /dev/null "$tree/backup.err"
  diff /dev/null "$tree/restore.err"
  normalize_restic_output < "$tree/restore.out" > "$tree/restore.normal"
  diff - "$tree/restore.normal" << 'EOF'
restoring snapshot ID of [/tmp/atc-gateway-backup] at NOW +0000 UTC by @atc-gateway to /tmp/tmp.X
Summary: Restored 2 files/dirs (SIZE) in T
EOF
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'cd /state && stat -c "%n %u %g %a" *.db' > "$tree/restored"
  diff - "$tree/restored" << 'EOF'
gateway.db 65532 65532 644
mcp-auth.db 65532 65532 600
EOF
  docker exec "$name" /usr/local/bin/atc-gateway clients list > "$tree/clients"
  diff - "$tree/clients" <<< "$client_id  fixture-client  https://client.fixture.invalid/callback"
}

# Three gateway snapshots from older images, each from its own per-run temp path, all on
# one fixed day: grouped by host and tags, retention keeps the newest of that day (old-c)
# and the group's oldest (old-a, kept while keep-daily is not used up) and forgets old-b.
# Grouped by path, as restic does by default, each would keep itself. The new snapshot's
# time comes from the wall clock, so the case checks it falls inside the backup's run,
# then masks it.
it_groups_the_gateway_snapshots_across_source_paths_when_a_backup_prunes() {
  local backup_image="$2" before after
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  run_backup_shell "$name" "$backup_image" "$tree" << 'EOF'
restic init -q
for s in a:10 b:11 c:12; do
  d="/tmp/old-${s%%:*}"
  mkdir -p "$d" && echo old > "$d/gateway.db"
  (cd "$d" && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 ${s#*:}:00:00" .)
done
sqlite3 /state/gateway.db 'CREATE TABLE fixture (x); INSERT INTO fixture VALUES (1);'
EOF
  before="$(date -u +%s)"

  run_backup "$name" "$backup_image" backup > "$tree/backup.out" 2> "$tree/backup.err"

  after="$(date -u +%s)"
  diff /dev/null "$tree/backup.err"
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'restic snapshots --json' > "$tree/snapshots"
  jq -S --argjson before "$before" --argjson after "$after" '[.[] | {paths, tags, hostname,
      time: (if .paths == ["/tmp/atc-gateway-backup"]
        then (.time | sub("\\.[0-9]+"; "") | fromdateiso8601 |
          if . >= $before and . <= $after then "within the backup run" else todate end)
        else .time end)}] | sort_by(.paths)' "$tree/snapshots" > "$tree/kept"
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
    "time": "within the backup run"
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
it_leaves_another_tools_snapshot_alone_when_a_backup_prunes() {
  local backup_image="$2"
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  run_backup_shell "$name" "$backup_image" "$tree" << 'EOF'
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
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'restic snapshots --json --tag other' > "$tree/other-before"

  run_backup "$name" "$backup_image" backup > "$tree/backup.out" 2> "$tree/backup.err"

  diff /dev/null "$tree/backup.err"
  jq -e 'length == 1' "$tree/other-before" > /dev/null
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'restic snapshots --json --tag other' > "$tree/other-after"
  jq -S . "$tree/other-before" > "$tree/other-before.json"
  jq -S . "$tree/other-after" > "$tree/other-after.json"
  diff "$tree/other-before.json" "$tree/other-after.json"
}

it_rejects_a_run_without_a_mode_with_its_usage() {
  local backup_image="$2" status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"

  run_backup "$name" "$backup_image" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: atc-gateway-backup backup|restore|ls'
  diff /dev/null "$tree/out"
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_rejects_an_unknown_mode_with_its_usage() {
  local backup_image="$2" status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"

  run_backup "$name" "$backup_image" prune > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: atc-gateway-backup backup|restore|ls'
  diff /dev/null "$tree/out"
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_stops_before_restic_when_STATE_DIR_is_unset() {
  local backup_image="$2" status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"

  docker run --rm --user 65532:65532 --security-opt no-new-privileges --cap-drop ALL \
    -e HOME=/tmp --tmpfs /tmp -v "$name-repo:/repo" -e RESTIC_REPOSITORY=/repo \
    -e RESTIC_PASSWORD=fixture-only "$backup_image" backup > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< '/usr/local/bin/atc-gateway-backup: line 14: STATE_DIR: set STATE_DIR'
  diff /dev/null "$tree/out"
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'ls -A /repo' > "$tree/repo"
  diff /dev/null "$tree/repo"
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_fails_a_backup_of_a_state_dir_without_databases() {
  local backup_image="$2" status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'restic init -q; echo notes > /state/readme'

  run_backup "$name" "$backup_image" backup > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'no databases in /state'
  diff /dev/null "$tree/out"
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'restic snapshots --json' > "$tree/snapshots"
  diff - "$tree/snapshots" <<< '[]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The database's index holds a key its table does not (row0010 rewritten as row0019), so
# sqlite3 .backup copies its pages whole and only the integrity check on the copy fails.
# The backup script pipes that check into `grep -qx ok`, so it fails without a message.
it_fails_a_backup_whose_copy_fails_the_integrity_check() {
  local backup_image="$2" status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
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
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'restic init -q; cp /seed/gateway.db /state/gateway.db'

  run_backup "$name" "$backup_image" backup > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff /dev/null "$tree/out"
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'restic snapshots --json' > "$tree/snapshots"
  diff - "$tree/snapshots" <<< '[]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The same index corruption, inside the latest gateway snapshot: the restore checks each
# database before it replaces anything, so the state keeps the database it had.
it_fails_a_restore_whose_snapshot_fails_the_integrity_check_and_keeps_the_state() {
  local backup_image="$2" status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
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
  run_backup_shell "$name" "$backup_image" "$tree" << 'EOF'
restic init -q
mkdir /tmp/snap && cp /seed/gateway.db /tmp/snap/gateway.db
(cd /tmp/snap && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
sqlite3 /state/gateway.db "CREATE TABLE f (v); INSERT INTO f VALUES ('current');"
EOF

  run_backup "$name" "$backup_image" restore > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @atc-gateway to /tmp/tmp.X
Summary: Restored 1 files/dirs (SIZE) in T
EOF
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'ls -A /state; sqlite3 /state/gateway.db "SELECT v FROM f"' > "$tree/state"
  diff - "$tree/state" << 'EOF'
gateway.db
current
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_a_restore_of_a_snapshot_without_databases() {
  local backup_image="$2" status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  run_backup_shell "$name" "$backup_image" "$tree" << 'EOF'
restic init -q
mkdir /tmp/snap && echo notes > /tmp/snap/readme
(cd /tmp/snap && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
EOF

  run_backup "$name" "$backup_image" restore > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'snapshot holds no databases'
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @atc-gateway to /tmp/tmp.X
Summary: Restored 1 files/dirs (SIZE) in T
EOF
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'ls -A /state' > "$tree/state"
  diff /dev/null "$tree/state"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_a_restore_when_the_repository_holds_no_gateway_snapshot() {
  local backup_image="$2" status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  run_backup_shell "$name" "$backup_image" "$tree" << 'EOF'
restic init -q
mkdir /tmp/other && echo other > /tmp/other/gateway.db
(cd /tmp/other && restic backup -q --tag other --host other --time "2020-01-06 10:00:00" .)
EOF

  run_backup "$name" "$backup_image" restore > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << 'EOF'
Fatal: failed to find snapshot: snapshot filter (Paths:[] Tags:[[atc-gateway]] Hosts:[atc-gateway]): no snapshot found
EOF
  diff /dev/null "$tree/out"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# ls lists the gateway's snapshots alone; each ID is random, so the case masks that column
it_lists_the_gateway_snapshots_alone_in_ls_mode() {
  local backup_image="$2" status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  run_backup_shell "$name" "$backup_image" "$tree" << 'EOF'
restic init -q
mkdir /tmp/a /tmp/other && echo a > /tmp/a/gateway.db && echo other > /tmp/other/f
(cd /tmp/a && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
(cd /tmp/a && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-07 10:00:00" .)
(cd /tmp/other && restic backup -q --tag other --host other --time "2020-01-06 09:00:00" .)
EOF

  run_backup "$name" "$backup_image" ls > "$tree/out" 2> "$tree/err" || status=$?

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
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_restores_the_snapshot_that_SNAPSHOT_names_instead_of_the_latest() {
  local backup_image="$2" older status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  run_backup_shell "$name" "$backup_image" "$tree" << 'EOF'
restic init -q
mkdir /tmp/snap
sqlite3 /tmp/snap/gateway.db "CREATE TABLE f (v); INSERT INTO f VALUES ('older');"
(cd /tmp/snap && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
sqlite3 /tmp/snap/gateway.db "UPDATE f SET v = 'newer';"
(cd /tmp/snap && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-07 10:00:00" .)
EOF
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'restic snapshots --json' > "$tree/snapshots"
  older="$(jq -r '.[] | select(.time == "2020-01-06T10:00:00Z") | .short_id' "$tree/snapshots")"
  [ -n "$older" ] || { echo "no snapshot from 2020-01-06" >&2; exit 1; }

  run_backup "$name" "$backup_image" -e "SNAPSHOT=$older" restore > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'sqlite3 /state/gateway.db "SELECT v FROM f"' > "$tree/value"
  diff - "$tree/value" <<< older
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_removes_stale_wal_and_shm_files_when_it_restores_a_database() {
  local backup_image="$2" status=0
  name="atc-gw-fixture-$BASHPID"
  tree="$(mktemp -d)"
  trap 'docker volume rm -f "$name-state" "$name-repo" > /dev/null || true; rm -rf "$tree" || true' EXIT
  setup_case "$tree" "$name" "$3"
  run_backup_shell "$name" "$backup_image" "$tree" << 'EOF'
restic init -q
mkdir /tmp/snap
sqlite3 /tmp/snap/gateway.db "CREATE TABLE f (v); INSERT INTO f VALUES ('restored');"
(cd /tmp/snap && restic backup -q --tag atc-gateway --host atc-gateway --time "2020-01-06 10:00:00" .)
echo stale > /state/gateway.db
echo stale-wal > /state/gateway.db-wal
echo stale-shm > /state/gateway.db-shm
echo kept > /state/other.db-wal
EOF

  run_backup "$name" "$backup_image" restore > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  run_backup_shell "$name" "$backup_image" "$tree" <<< 'ls -A /state; sqlite3 /state/gateway.db "SELECT v FROM f"' > "$tree/state"
  diff - "$tree/state" << 'EOF'
gateway.db
other.db-wal
restored
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# Boot data every case needs: the registry the gateway reads, whose daemon is a dead
# address (the gateway serves without reaching it), a seed directory the backup shell
# reads at /seed, and a state volume and a restic repository volume owned by the nonroot
# uid, as fsGroup 65532 leaves the pod's new volume.
setup_case() {
  local tree="$1" name="$2" restic_image="$3"
  mkdir "$tree/registry" "$tree/seed"
  printf '%s' '{"daemons":{"geoffcloud":{"address":"127.0.0.1:1","daemonID":"00000000-0000-4000-8000-000000000000"}},"defaultDaemon":"geoffcloud"}' \
    > "$tree/registry/registry.json"
  chmod -R a+rwX "$tree/seed"
  chmod -R a+rX "$tree"
  docker volume create "$name-state" > /dev/null
  docker volume create "$name-repo" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-state:/s" -v "$name-repo:/r" \
    "$restic_image" -c 'chown 65532:65532 /s /r'
}

# The container as the Deployment runs it: a read-only root, no new privileges, every
# capability dropped, the same tmpfs mounts, env and args, on an ephemeral loopback port.
start_gateway() {
  local name="$1" tree="$2" image="$3"
  docker run -d --name "$name" --read-only --security-opt no-new-privileges --cap-drop ALL \
    --tmpfs /run/atc:uid=65532,gid=65532 --tmpfs /tmp:exec \
    --tmpfs /home/nonroot/.config:uid=65532,gid=65532 \
    -v "$name-state:/home/nonroot/.local/state/atc" -v "$tree/registry:/etc/atc-gateway:ro" \
    -p 127.0.0.1::8414 -e ATC_GATEWAY_TOKEN_GEOFFCLOUD=fixture-only \
    -e ATC_GATEWAY_STATE_DIR=/home/nonroot/.local/state/atc \
    "$image" serve --host 0.0.0.0 --port 8414 --public-url https://atc.fixture.invalid \
    --registry /etc/atc-gateway/registry.json --state-dir /home/nonroot/.local/state/atc > /dev/null
  wait_for_ready "$name"
}

# Polls /readyz on the public Host until it answers 200, for at most 30 seconds; past the
# deadline it prints the container's logs and fails.
wait_for_ready() {
  local name="$1" port
  port="$(docker port "$name" 8414/tcp)"
  port="${port##*:}"
  if ! wait_for 30 "$name to answer /readyz with 200" is_ready "$port"; then
    docker logs "$name" 2>&1 | tail -20 >&2
    return 1
  fi
}

is_ready() {
  [ "$(curl -q --noproxy '*' -s -o /dev/null -w '%{http_code}' -H 'Host: atc.fixture.invalid' \
    "http://127.0.0.1:$1/readyz")" = 200 ]
}

# The backup image as the backup CronJob and the restore Job run it: uid and gid 65532,
# no privilege escalation, every capability dropped, HOME=/tmp on a writable /tmp (an
# emptyDir there). Neither pod sets readOnlyRootFilesystem, so neither does this. Extra
# `docker run` options (such as -e SNAPSHOT=…) go before the image.
run_backup() {
  local name="$1" image="$2"
  shift 2
  local options=()
  while [ "$#" -gt 0 ] && [[ "$1" == -* ]]; do
    options+=("$1" "$2")
    shift 2
  done
  docker run --rm --user 65532:65532 --security-opt no-new-privileges --cap-drop ALL \
    -e HOME=/tmp --tmpfs /tmp -v "$name-state:/state" -v "$name-repo:/repo" \
    -e STATE_DIR=/state -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only \
    "${options[@]}" "$image" "$@"
}

# A shell in the backup image under the same uid and security, with the same volumes and
# repository, and the case's seed directory (<tree>/seed) at /seed; it runs the script on stdin with
# errexit, for arranging snapshots and state and for reading them back.
run_backup_shell() {
  local name="$1" image="$2" tree="$3"
  docker run --rm -i --user 65532:65532 --security-opt no-new-privileges --cap-drop ALL \
    -e HOME=/tmp --tmpfs /tmp -v "$name-state:/state" -v "$name-repo:/repo" \
    -v "$tree/seed:/seed:ro" -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=fixture-only \
    --entrypoint /bin/sh "$image" -es
}

# Masks what restic prints that changes from run to run: snapshot IDs, the wall-clock time
# of a new snapshot (seeded snapshots keep their 2020 times), durations, sizes and the
# restore's temp directory.
normalize_restic_output() {
  sed -E \
    -e 's/^[0-9a-f]{8}  /ID  /' \
    -e 's/snapshot [0-9a-f]{8} /snapshot ID /' \
    -e 's/20(2[1-9]|[3-9][0-9])-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?/NOW/g' \
    -e 's/2020-([0-9]{2})-([0-9]{2}) ([0-9:]{8})\.0+ /2020-\1-\2 \3 /g' \
    -e 's/[0-9]+(\.[0-9]+)? (B|KiB|MiB)/SIZE/g' \
    -e 's/ in [0-9]+:[0-9]{2}/ in T/' \
    -e 's/^\[[0-9]+:[0-9]{2}\] /[T] /' \
    -e 's#/tmp/tmp\.[A-Za-z0-9]+#/tmp/tmp.X#'
}

# Builds both images once under per-run tags that the run removes, then runs the cases
# with the image names (and the pinned restic image) as their arguments.
run_suite() {
  local repo work gateway_image backup_image
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # sets BASE_IMAGE and RESTIC_IMAGE, among the pins
  # shellcheck source=/dev/null
  source "$repo/deploy/atc-gateway/versions.env"
  work="$(mktemp -d)"
  gateway_image="atc-gateway:fixture-$$"
  backup_image="atc-gateway-backup:fixture-$$"
  # expanded now: the trap runs after run_suite returns and its locals are gone
  # shellcheck disable=SC2064
  trap "docker rmi -f '$gateway_image' '$backup_image' > /dev/null 2>&1 || true; rm -rf '$work' || true" EXIT
  # shellcheck disable=SC2153 # RESTIC_IMAGE comes from versions.env
  if ! {
    "$repo/scripts/fetch-atc-release.sh" "$work/context" &&
      cp "$repo/deploy/atc-gateway/Dockerfile" "$work/context/" &&
      docker build -q --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$gateway_image" "$work/context" &&
      docker build -q --build-arg "RESTIC_IMAGE=$RESTIC_IMAGE" -t "$backup_image" \
        "$repo/deploy/atc-gateway/backup"
  } > "$work/build.log" 2>&1; then
    echo "FAIL the images did not build from the pinned, checked binary and pinned bases"
    sed 's/^/    /' "$work/build.log"
    exit 1
  fi
  echo "built $gateway_image and $backup_image"
  run_cases "$gateway_image" "$backup_image" "$RESTIC_IMAGE"
}

run_suite
