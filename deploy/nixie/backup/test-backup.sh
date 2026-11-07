#!/usr/bin/env bash
# Fixture test for nixie's backup and restore, run locally with Docker in the nixie-backup image
# that the stack config pins as nixie.backupImage. It touches no cluster and no cloud account.
#
# It runs the image as the backup CronJob runs it (infra/cluster/build-nixie-backup-pod-spec.ts):
# nixie's uid and gid 10001, a read-only root, the staging init container, then the image's own job
# on the staging folder of the data volume, with a local data repo and key repo. It runs the
# restore script as the restore Job's fetch container runs it
# (infra/cluster/build-nixie-restore-pod-spec.ts): the script mounted read-only and run by /bin/sh
# in place of the image's job, writing into the directory it shares with `nixie restore` at
# /tmp/nixie-backup. A set's copies are opaque bytes, because only nixie's commands open its
# databases, and their tests live in nixie. What this proves: the pod's wiring ships a staged set to
# both repos, records the receipt and removes the copies; the key repo keeps only the newest set;
# a restore takes keys.db from the key repo's highest set, read from the snapshots' tags, and the
# nixie.db of the same set, or the one SNAPSHOT names; the refusals, ls and the usage. What it does not prove: R2, k3s, and nixie's staging and
# commands, which the restore test in docs/runbooks/nixie-backup.md covers.
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
source "$(dirname "${BASH_SOURCE[0]}")/../../../test-support/shell/normalize-restic-output.sh"

# the cleanup every case passes to create_case_tree: the containers first, then the volumes
cleanup='docker rm -f "$name-staging" "$name-job" "$name-restore" "$name-shell" "$name-setup" > /dev/null 2>&1 || true; docker volume rm -f "$name-state" "$name-data" "$name-keys" "$name-copy" > /dev/null || true'

it_publishes_a_staged_set_to_both_repos_and_leaves_only_its_receipt_and_marker() {
  local image="$1" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  stage_sets "$name" "$image" 1:scheduled

  run_job "$name" "$image" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  sed -E 's/"time":"[^"]+",//' "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
nixie-backup (nixie-backup)

{"event":"backup.set_published","sequence":1}
EOF
  assert_status 0 "$status"
  run_shell "$name" "$image" > "$tree/state" << 'EOF'
ls -A /state/backup/000000000001
EOF
  diff - "$tree/state" << 'EOF'
complete
manifest.json
receipt.json
EOF
  read_repos "$name" "$image" "$tree"
  jq -c '{status, sequence, prune, check, failure, removed: (.removedKeySnapshotIDs | length)}' \
    "$tree/receipt-1" > "$tree/receipt"
  diff - "$tree/receipt" <<< '{"status":"published","sequence":1,"prune":"passed","check":"passed","failure":null,"removed":0}'
  jq -c '[.[] | {paths, tags}]' "$tree/data.json" > "$tree/data"
  diff - "$tree/data" <<< '[{"paths":["/nixie.db"],"tags":["set-1","kind-scheduled"]}]'
  jq -c '[.[] | {paths, tags}]' "$tree/keys.json" > "$tree/keys"
  diff - "$tree/keys" <<< '[{"paths":["/keys.db"],"tags":["set-1","kind-scheduled"]}]'
  [ "$(jq -r .dataSnapshotID "$tree/receipt-1")" = "$(jq -r '.[0].id' "$tree/data.json")" ]
  [ "$(jq -r .keySnapshotID "$tree/receipt-1")" = "$(jq -r '.[0].id' "$tree/keys.json")" ]
}

# a forget stages a set at once, and its key snapshot must be the only one left
it_keeps_the_newest_sets_key_snapshot_alone_and_every_data_snapshot() {
  local image="$1" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  stage_sets "$name" "$image" 1:scheduled
  run_job "$name" "$image" > /dev/null
  stage_sets "$name" "$image" 2:forget

  run_job "$name" "$image" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  sed -E 's/"time":"[^"]+",//' "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
nixie-backup (nixie-backup)

{"event":"backup.set_published","sequence":2}
EOF
  assert_status 0 "$status"
  read_repos "$name" "$image" "$tree"
  jq -c '[.[] | {paths, tags}]' "$tree/keys.json" > "$tree/keys"
  diff - "$tree/keys" <<< '[{"paths":["/keys.db"],"tags":["set-2","kind-forget"]}]'
  jq -c '[.[] | .tags[0]] | sort' "$tree/data.json" > "$tree/data"
  diff - "$tree/data" <<< '["set-1","set-2"]'
  jq -c '{status, removed: (.removedKeySnapshotIDs | length)}' "$tree/receipt-2" > "$tree/receipt"
  diff - "$tree/receipt" <<< '{"status":"published","removed":1}'
}

# The data repo's newest snapshot is set 3's, whose key snapshot never landed, as a failed key step
# leaves it; the restore still pairs the key repo's set 2 with set 2's nixie.db.
it_restores_keys_db_and_the_nixie_db_of_the_same_set_from_the_two_repos() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  stage_sets "$name" "$image" 1:scheduled
  run_job "$name" "$image" > /dev/null
  stage_sets "$name" "$image" 2:forget
  run_job "$name" "$image" > /dev/null
  run_shell "$name" "$image" << 'EOF'
echo 'nixie.db of set 3' | RESTIC_REPOSITORY=/repos/data RESTIC_PASSWORD=data-fixture-only \
  restic backup -q --host nixie --tag set-3 --tag kind-scheduled --stdin --stdin-filename nixie.db
EOF

  run_restore "$name" "$image" "$script" restore > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
restoring snapshot ID of [/nixie.db] at NOW +0000 UTC by nixie@nixie to /tmp/nixie-backup
Summary: Restored 1 files/dirs (SIZE) in T
restoring snapshot ID of [/keys.db] at NOW +0000 UTC by nixie@nixie to /tmp/nixie-backup
Summary: Restored 1 files/dirs (SIZE) in T
EOF
  assert_status 0 "$status"
  run_shell "$name" "$image" > "$tree/copy" << 'EOF'
cd /tmp/nixie-backup && stat -c '%n %u:%g' * | sort
cat nixie.db keys.db
EOF
  diff - "$tree/copy" << 'EOF'
keys.db 10001:10001
nixie.db 10001:10001
nixie.db of set 2
keys.db of set 2
EOF
}

# Set 2's key snapshot stays beside set 10's, as a failed removal leaves it. restic lists snapshots
# oldest first, and set-10 sorts before set-2 as text, so only the set's number picks set 10.
it_restores_the_set_with_the_highest_number_when_the_key_repo_holds_two() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  run_shell "$name" "$image" << 'EOF'
RESTIC_REPOSITORY=/repos/data RESTIC_PASSWORD=data-fixture-only restic init -q
RESTIC_REPOSITORY=/repos/keys RESTIC_PASSWORD=key-fixture-only restic init -q
for sequence in 2 10; do
  echo "nixie.db of set $sequence" | RESTIC_REPOSITORY=/repos/data RESTIC_PASSWORD=data-fixture-only \
    restic backup -q --host nixie --tag "set-$sequence" --tag kind-scheduled --stdin \
    --stdin-filename nixie.db
  echo "keys.db of set $sequence" | RESTIC_REPOSITORY=/repos/keys RESTIC_PASSWORD=key-fixture-only \
    restic backup -q --host nixie --tag "set-$sequence" --tag kind-scheduled --stdin \
    --stdin-filename keys.db
done
EOF

  run_restore "$name" "$image" "$script" restore > /dev/null 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  assert_status 0 "$status"
  run_shell "$name" "$image" > "$tree/copy" <<< 'cat /tmp/nixie-backup/nixie.db /tmp/nixie-backup/keys.db'
  diff - "$tree/copy" << 'EOF'
nixie.db of set 10
keys.db of set 10
EOF
}

# A snapshot's host, like its paths, is free text that can read set-<n>; only its tags name a set.
it_reads_a_backup_set_only_from_a_snapshots_tags() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  stage_sets "$name" "$image" 1:scheduled
  run_job "$name" "$image" > /dev/null
  run_shell "$name" "$image" << 'EOF'
echo 'a note' | RESTIC_REPOSITORY=/repos/keys RESTIC_PASSWORD=key-fixture-only \
  restic backup -q --host set-99 --stdin --stdin-filename set-99
EOF

  run_restore "$name" "$image" "$script" restore > /dev/null 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  assert_status 0 "$status"
  run_shell "$name" "$image" > "$tree/copy" <<< 'cat /tmp/nixie-backup/nixie.db /tmp/nixie-backup/keys.db'
  diff - "$tree/copy" << 'EOF'
nixie.db of set 1
keys.db of set 1
EOF
}

# an older nixie.db beside the newest keys.db keeps every forget since
it_restores_the_nixie_db_that_SNAPSHOT_names_beside_the_newest_keys_db() {
  local image="$1" script="$2" older status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  stage_sets "$name" "$image" 1:scheduled
  run_job "$name" "$image" > /dev/null
  stage_sets "$name" "$image" 2:scheduled
  run_job "$name" "$image" > /dev/null
  read_repos "$name" "$image" "$tree"
  older="$(jq -r .dataSnapshotID "$tree/receipt-1")"

  run_restore "$name" "$image" "$script" -e "SNAPSHOT=$older" restore > /dev/null 2> "$tree/err" ||
    status=$?

  diff /dev/null "$tree/err"
  assert_status 0 "$status"
  run_shell "$name" "$image" > "$tree/copy" <<< 'cat /tmp/nixie-backup/nixie.db /tmp/nixie-backup/keys.db'
  diff - "$tree/copy" << 'EOF'
nixie.db of set 1
keys.db of set 2
EOF
}

# set 2's data snapshot landed and its key snapshot did not, so set 2's records have no keys
it_refuses_a_SNAPSHOT_whose_set_is_newer_than_the_key_repos() {
  local image="$1" script="$2" newer status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  stage_sets "$name" "$image" 1:scheduled
  run_job "$name" "$image" > /dev/null
  newer="$(
    run_shell "$name" "$image" << 'EOF'
echo 'nixie.db of set 2' | RESTIC_REPOSITORY=/repos/data RESTIC_PASSWORD=data-fixture-only \
  restic backup -q --json --host nixie --tag set-2 --tag kind-scheduled --stdin --stdin-filename nixie.db |
  grep -o '"snapshot_id":"[0-9a-f]*"' | cut -d'"' -f4
EOF
  )"

  run_restore "$name" "$image" "$script" -e "SNAPSHOT=$newer" restore > "$tree/out" 2> "$tree/err" ||
    status=$?

  diff - "$tree/err" <<< "the data snapshot $newer holds set-2, newer than the key repo's set-1"
  diff /dev/null "$tree/out"
  assert_status 1 "$status"
  run_shell "$name" "$image" > "$tree/copy" <<< 'ls -A /tmp/nixie-backup'
  diff /dev/null "$tree/copy"
}

# a snapshot with no set tag, such as one tagged nixie that holds both databases, pairs with no
# key snapshot
it_refuses_a_SNAPSHOT_that_holds_no_backup_set() {
  local image="$1" script="$2" old status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  stage_sets "$name" "$image" 1:scheduled
  run_job "$name" "$image" > /dev/null
  old="$(
    run_shell "$name" "$image" << 'EOF'
mkdir /tmp/old && echo old > /tmp/old/nixie.db && echo old > /tmp/old/keys.db
cd /tmp/old && RESTIC_REPOSITORY=/repos/data RESTIC_PASSWORD=data-fixture-only \
  restic backup -q --json --host nixie --tag nixie . | grep -o '"snapshot_id":"[0-9a-f]*"' | cut -d'"' -f4
EOF
  )"

  run_restore "$name" "$image" "$script" -e "SNAPSHOT=$old" restore > "$tree/out" 2> "$tree/err" ||
    status=$?

  diff - "$tree/err" <<< "the data snapshot $old holds no backup set"
  diff /dev/null "$tree/out"
  assert_status 1 "$status"
  run_shell "$name" "$image" > "$tree/copy" <<< 'ls -A /tmp/nixie-backup'
  diff /dev/null "$tree/copy"
}

# a copy directory that holds files already would mix them into the restore
it_refuses_a_restore_into_a_copy_directory_that_is_not_empty() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  stage_sets "$name" "$image" 1:scheduled
  run_job "$name" "$image" > /dev/null
  run_shell "$name" "$image" <<< "echo 'already here' > /tmp/nixie-backup/nixie.db"

  run_restore "$name" "$image" "$script" restore > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< '/tmp/nixie-backup is not empty'
  diff /dev/null "$tree/out"
  assert_status 1 "$status"
  run_shell "$name" "$image" > "$tree/copy" <<< 'ls -A /tmp/nixie-backup; cat /tmp/nixie-backup/nixie.db'
  diff - "$tree/copy" << 'EOF'
nixie.db
already here
EOF
}

# before the job's first set, the key repo holds no keys.db to pair with any nixie.db
it_refuses_a_restore_while_the_key_repo_holds_no_snapshot() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  run_shell "$name" "$image" << 'EOF'
RESTIC_REPOSITORY=/repos/data RESTIC_PASSWORD=data-fixture-only restic init -q
RESTIC_REPOSITORY=/repos/keys RESTIC_PASSWORD=key-fixture-only restic init -q
EOF

  run_restore "$name" "$image" "$script" restore > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the key repo holds no snapshot of a backup set'
  diff /dev/null "$tree/out"
  assert_status 1 "$status"
  run_shell "$name" "$image" > "$tree/copy" <<< 'ls -A /tmp/nixie-backup'
  diff /dev/null "$tree/copy"
}

# each ID and time is new on every run, so the case masks them
it_lists_both_repos_in_ls_mode() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"
  stage_sets "$name" "$image" 1:forget
  run_job "$name" "$image" > /dev/null

  run_restore "$name" "$image" "$script" ls > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  normalize_restic_output < "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
data repo:
ID        Time                 Host        Tags               Paths      Size
-----------------------------------------------------------------------------
ID  NOW  nixie       set-1,kind-forget  /nixie.db  SIZE
-----------------------------------------------------------------------------
Timestamps shown in local time
1 snapshots
key repo:
ID        Time                 Host        Tags               Paths     Size
----------------------------------------------------------------------------
ID  NOW  nixie       set-1,kind-forget  /keys.db  SIZE
----------------------------------------------------------------------------
Timestamps shown in local time
1 snapshots
EOF
  assert_status 0 "$status"
}

it_rejects_an_unknown_mode_with_its_usage() {
  local image="$1" script="$2" status=0
  name="nixie-backup-$3-$BASHPID"
  create_case_tree "$cleanup"
  setup_test "$name" "$image"

  run_restore "$name" "$image" "$script" backup > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: nixie-restore restore|ls'
  diff /dev/null "$tree/out"
  assert_status 2 "$status"
}

# Boot data every case needs: the data volume, the two repos and the restore's copy directory,
# each owned by nixie's uid, as fsGroup 10001 leaves the pod's volumes. Its chown container is
# named for the case's trap.
setup_test() {
  local name="$1" image="$2" volume
  for volume in state data keys copy; do
    docker volume create "$name-$volume" > /dev/null
  done
  docker run --rm --name "$name-setup" --user 0 --entrypoint /bin/sh \
    -v "$name-state:/s" -v "$name-data:/d" -v "$name-keys:/k" -v "$name-copy:/c" "$image" \
    -c 'chown 10001:10001 /s /d /k /c'
}

# stage_sets <name> <image> <sequence>:<kind>...: writes each set into the staging folder as nixie
# stages one: both copies, the manifest with each copy's size and checksum, then the marker last
stage_sets() {
  local name="$1" image="$2"
  shift 2
  run_shell "$name" "$image" -e "SETS=$*" << 'EOF'
mkdir -p -m 0700 /state/backup
for set in $SETS; do
  sequence="${set%%:*}"
  dir="/state/backup/$(printf '%012d' "$sequence")"
  mkdir -m 0700 "$dir"
  copies=""
  for file in nixie.db keys.db; do
    printf '%s of set %s\n' "$file" "$sequence" > "$dir/$file"
    sum="$(sha256sum "$dir/$file" | cut -d' ' -f1)"
    copies="$copies${copies:+,}{\"name\":\"$file\",\"bytes\":$(stat -c %s "$dir/$file"),\"sha256\":\"$sum\"}"
  done
  printf '{"format":1,"kind":"%s","sequence":%s,"stagedAt":1798761600000,"copies":[%s]}\n' \
    "${set#*:}" "$sequence" "$copies" > "$dir/manifest.json"
  : > "$dir/complete"
done
EOF
}

# read_repos <name> <image> <tree>: writes each repo's snapshots as JSON to <tree>/data.json and
# <tree>/keys.json, and each set's receipt to <tree>/receipt-<sequence>
read_repos() {
  local name="$1" image="$2" tree="$3" sequence
  run_shell "$name" "$image" > "$tree/data.json" <<< \
    'RESTIC_REPOSITORY=/repos/data RESTIC_PASSWORD=data-fixture-only restic snapshots --json'
  run_shell "$name" "$image" > "$tree/keys.json" <<< \
    'RESTIC_REPOSITORY=/repos/keys RESTIC_PASSWORD=key-fixture-only restic snapshots --json'
  for sequence in 1 2; do
    run_shell "$name" "$image" > "$tree/receipt-$sequence" <<< \
      "cat /state/backup/$(printf '%012d' "$sequence")/receipt.json 2> /dev/null || true"
  done
}

# run_job <name> <image>: one run of the CronJob's pod, the staging init container then the job,
# with the pod's user, security settings and mounts, and the two local repos in place of R2
run_job() {
  local name="$1" image="$2"
  docker run --rm --name "$name-staging" --user 10001:10001 --security-opt no-new-privileges \
    --cap-drop ALL --read-only -v "$name-state:/state" --entrypoint mkdir "$image" \
    -p -m 0700 /state/backup
  docker run --rm --name "$name-job" --user 10001:10001 --security-opt no-new-privileges \
    --cap-drop ALL --read-only --tmpfs /tmp -e HOME=/tmp -e NIXIE_BACKUP_STAGING_DIR=/backup \
    --mount "type=volume,src=$name-state,dst=/backup,volume-subpath=backup" \
    -v "$name-data:/repos/data" -v "$name-keys:/repos/keys" \
    -e NIXIE_BACKUP_DATA_REPOSITORY=/repos/data -e NIXIE_BACKUP_DATA_PASSWORD=data-fixture-only \
    -e NIXIE_BACKUP_KEY_REPOSITORY=/repos/keys -e NIXIE_BACKUP_KEY_PASSWORD=key-fixture-only \
    "$image" run
}

# run_restore <name> <image> <script> [<docker run option> <value>]... <arg>...: the restore Job's
# fetch container, with SNAPSHOT empty as the Job sets it; leading options go to docker run in pairs
run_restore() {
  local name="$1" image="$2" script="$3"
  shift 3
  local options=()
  while [ "$#" -gt 1 ] && [[ "$1" == -* ]]; do
    options+=("$1" "$2")
    shift 2
  done
  docker run --rm --name "$name-restore" --user 10001:10001 --security-opt no-new-privileges \
    --cap-drop ALL --tmpfs /tmp -e HOME=/tmp -e SNAPSHOT= -v "$name-copy:/tmp/nixie-backup" \
    -v "$name-data:/repos/data" -v "$name-keys:/repos/keys" \
    -e NIXIE_BACKUP_DATA_REPOSITORY=/repos/data -e NIXIE_BACKUP_DATA_PASSWORD=data-fixture-only \
    -e NIXIE_BACKUP_KEY_REPOSITORY=/repos/keys -e NIXIE_BACKUP_KEY_PASSWORD=key-fixture-only \
    -v "$script:/opt/nixie-backup/restore.sh:ro" "${options[@]}" --entrypoint /bin/sh "$image" \
    /opt/nixie-backup/restore.sh "$@"
}

# run_shell <name> <image> [<docker run option> <value>]...: a shell as nixie's uid with every
# volume mounted, which runs the script on stdin with errexit, for arranging and reading state
run_shell() {
  local name="$1" image="$2"
  shift 2
  docker run --rm -i --name "$name-shell" --user 10001:10001 --security-opt no-new-privileges \
    --cap-drop ALL --tmpfs /tmp -e HOME=/tmp -v "$name-state:/state" \
    -v "$name-data:/repos/data" -v "$name-keys:/repos/keys" -v "$name-copy:/tmp/nixie-backup" \
    "$@" --entrypoint /bin/sh "$image" -es
}

# Boot data every case needs: the nixie-backup image the stack config pins (nixie.backupImage),
# pulled once, and the script under test, by absolute path for the bind mount.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
image="$(cd "$repo" && bun -e 'console.log(Bun.YAML.parse(await Bun.file("infra/Pulumi.prod.yaml").text()).config["geoff-cloud:nixie"].backupImage)')"
docker pull -q "$image" > /dev/null
run="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
run_cases "$image" "$repo/deploy/nixie/backup/restore.sh" "$run"
