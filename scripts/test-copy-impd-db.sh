#!/usr/bin/env bash
# Hermetic test for copy-impd-db.sh: it checks the label, then sends the host one
# `bash -c` command that takes the copy, with the label as its only argument, to
# root@geoffcloud or the host IMPD_DB_HOST names, and passes the host's report and exit code
# through. It touches no host: ssh is a stand-in from test-lib that logs its argv as a JSON
# line and answers as the host does, without running the remote command, which needs root,
# Nix and the imp-host container. One case hands ssh to the real ssh, refused by a dead
# loopback port. Each case runs the script under `env -i` with only the variables it sets
# and compares its whole stdout, stderr and call log, and its exact exit code; the expected
# call holds the remote command the script sends, written out here.
#
#   bash scripts/test-copy-impd-db.sh
#   CASE='label' bash scripts/test-copy-impd-db.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-impd-db-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/require-remote-tool-stubs.sh"

it_sends_the_copy_to_geoffcloud_with_the_label_and_prints_the_hosts_report() {
  local remote status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  remote="$(
    cat << 'REMOTE'
set -euo pipefail
umask 077
nix() { command nix --extra-experimental-features "nix-command flakes" "$@"; }
static=$(nix build --no-link --print-out-paths nixpkgs#pkgsStatic.sqlite.bin)/bin/sqlite3
sqlite=$(nix build --no-link --print-out-paths nixpkgs#sqlite.bin)/bin/sqlite3
mkdir -p -m 0700 /root/imp-db-backups
dir=/root/imp-db-backups/$1-$(date -u +%Y%m%dT%H%M%S)
mkdir -m 0700 "$dir"
work=$(docker exec imp-host sh -c "umask 077; mktemp -d /tmp/impd-db-copy.XXXXXX")
case $work in /tmp/impd-db-copy.??????) ;; *) echo "unexpected work dir: $work" >&2; exit 1 ;; esac
trap "docker exec imp-host rm -rf -- \"$work\"" EXIT
docker cp "$static" "imp-host:$work/sqlite3"
docker exec imp-host sh -c "umask 077; \"\$1/sqlite3\" /var/lib/imp/db/imp.sqlite \"VACUUM INTO '\$1/imp.sqlite'\"" _ "$work"
docker cp "imp-host:$work/imp.sqlite" "$dir/imp.sqlite"
chmod 0600 "$dir/imp.sqlite"
integrity=$("$sqlite" "$dir/imp.sqlite" "PRAGMA integrity_check;")
migration=$("$sqlite" "$dir/imp.sqlite" "SELECT name FROM kysely_migration ORDER BY name DESC LIMIT 1;")
version=$(docker exec imp-host imp info | sed -n "s/^version *//p")
image=$(docker inspect imp-host --format "{{.Config.Image}}")
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
size=$(stat -c %s "$dir/imp.sqlite")
# the field names match `imp db copy --json` (imp #171); impd cannot know the image, so cloud adds it
printf "path %s\nsizeBytes %s\nlastMigration %s\nimpVersion %s\ncreatedAt %s\nintegrity %s\nimage %s\n" \
  "$dir/imp.sqlite" "$size" "$migration" "$version" "$created" "$integrity" "$image" > "$dir/COPY-INFO"
cat "$dir/COPY-INFO"
echo "copy: $dir ($(stat -c "%s bytes, mode %a" "$dir/imp.sqlite"))"
test "$integrity" = ok
REMOTE
  )"
  jq -cn --arg command "bash -c $(printf '%q' "$remote") _ imp-0.29.0-pre-0.30.0" \
    '["ssh","-o","BatchMode=yes","root@geoffcloud",$command]' > "$tree/calls-expected"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash copy-impd-db.sh imp-0.29.0-pre-0.30.0) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
path /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity ok
image ghcr.io/zgeoff/imp:0.29.0
copy: /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000 (73728 bytes, mode 600)
OUT
  diff /dev/null "$tree/err"
  diff "$tree/calls-expected" "$tree/calls"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_sends_the_copy_to_the_host_IMPD_DB_HOST_names() {
  local remote status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  remote="$(
    cat << 'REMOTE'
set -euo pipefail
umask 077
nix() { command nix --extra-experimental-features "nix-command flakes" "$@"; }
static=$(nix build --no-link --print-out-paths nixpkgs#pkgsStatic.sqlite.bin)/bin/sqlite3
sqlite=$(nix build --no-link --print-out-paths nixpkgs#sqlite.bin)/bin/sqlite3
mkdir -p -m 0700 /root/imp-db-backups
dir=/root/imp-db-backups/$1-$(date -u +%Y%m%dT%H%M%S)
mkdir -m 0700 "$dir"
work=$(docker exec imp-host sh -c "umask 077; mktemp -d /tmp/impd-db-copy.XXXXXX")
case $work in /tmp/impd-db-copy.??????) ;; *) echo "unexpected work dir: $work" >&2; exit 1 ;; esac
trap "docker exec imp-host rm -rf -- \"$work\"" EXIT
docker cp "$static" "imp-host:$work/sqlite3"
docker exec imp-host sh -c "umask 077; \"\$1/sqlite3\" /var/lib/imp/db/imp.sqlite \"VACUUM INTO '\$1/imp.sqlite'\"" _ "$work"
docker cp "imp-host:$work/imp.sqlite" "$dir/imp.sqlite"
chmod 0600 "$dir/imp.sqlite"
integrity=$("$sqlite" "$dir/imp.sqlite" "PRAGMA integrity_check;")
migration=$("$sqlite" "$dir/imp.sqlite" "SELECT name FROM kysely_migration ORDER BY name DESC LIMIT 1;")
version=$(docker exec imp-host imp info | sed -n "s/^version *//p")
image=$(docker inspect imp-host --format "{{.Config.Image}}")
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
size=$(stat -c %s "$dir/imp.sqlite")
# the field names match `imp db copy --json` (imp #171); impd cannot know the image, so cloud adds it
printf "path %s\nsizeBytes %s\nlastMigration %s\nimpVersion %s\ncreatedAt %s\nintegrity %s\nimage %s\n" \
  "$dir/imp.sqlite" "$size" "$migration" "$version" "$created" "$integrity" "$image" > "$dir/COPY-INFO"
cat "$dir/COPY-INFO"
echo "copy: $dir ($(stat -c "%s bytes, mode %a" "$dir/imp.sqlite"))"
test "$integrity" = ok
REMOTE
  )"
  jq -cn --arg command "bash -c $(printf '%q' "$remote") _ imp-0.29.0-pre-0.30.0" \
    '["ssh","-o","BatchMode=yes","root@imp-staging",$command]' > "$tree/calls-expected"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@imp-staging IMPD_DB_HOST=root@imp-staging bash copy-impd-db.sh imp-0.29.0-pre-0.30.0) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
path /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity ok
image ghcr.io/zgeoff/imp:0.29.0
copy: /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000 (73728 bytes, mode 600)
OUT
  diff /dev/null "$tree/err"
  diff "$tree/calls-expected" "$tree/calls"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_exits_1_with_the_hosts_report_when_the_copy_fails_its_integrity_check() {
  local remote status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  remote="$(
    cat << 'REMOTE'
set -euo pipefail
umask 077
nix() { command nix --extra-experimental-features "nix-command flakes" "$@"; }
static=$(nix build --no-link --print-out-paths nixpkgs#pkgsStatic.sqlite.bin)/bin/sqlite3
sqlite=$(nix build --no-link --print-out-paths nixpkgs#sqlite.bin)/bin/sqlite3
mkdir -p -m 0700 /root/imp-db-backups
dir=/root/imp-db-backups/$1-$(date -u +%Y%m%dT%H%M%S)
mkdir -m 0700 "$dir"
work=$(docker exec imp-host sh -c "umask 077; mktemp -d /tmp/impd-db-copy.XXXXXX")
case $work in /tmp/impd-db-copy.??????) ;; *) echo "unexpected work dir: $work" >&2; exit 1 ;; esac
trap "docker exec imp-host rm -rf -- \"$work\"" EXIT
docker cp "$static" "imp-host:$work/sqlite3"
docker exec imp-host sh -c "umask 077; \"\$1/sqlite3\" /var/lib/imp/db/imp.sqlite \"VACUUM INTO '\$1/imp.sqlite'\"" _ "$work"
docker cp "imp-host:$work/imp.sqlite" "$dir/imp.sqlite"
chmod 0600 "$dir/imp.sqlite"
integrity=$("$sqlite" "$dir/imp.sqlite" "PRAGMA integrity_check;")
migration=$("$sqlite" "$dir/imp.sqlite" "SELECT name FROM kysely_migration ORDER BY name DESC LIMIT 1;")
version=$(docker exec imp-host imp info | sed -n "s/^version *//p")
image=$(docker inspect imp-host --format "{{.Config.Image}}")
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
size=$(stat -c %s "$dir/imp.sqlite")
# the field names match `imp db copy --json` (imp #171); impd cannot know the image, so cloud adds it
printf "path %s\nsizeBytes %s\nlastMigration %s\nimpVersion %s\ncreatedAt %s\nintegrity %s\nimage %s\n" \
  "$dir/imp.sqlite" "$size" "$migration" "$version" "$created" "$integrity" "$image" > "$dir/COPY-INFO"
cat "$dir/COPY-INFO"
echo "copy: $dir ($(stat -c "%s bytes, mode %a" "$dir/imp.sqlite"))"
test "$integrity" = ok
REMOTE
  )"
  jq -cn --arg command "bash -c $(printf '%q' "$remote") _ imp-0.29.0-pre-0.30.0" \
    '["ssh","-o","BatchMode=yes","root@geoffcloud",$command]' > "$tree/calls-expected"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_COPY_FAIL=integrity bash copy-impd-db.sh imp-0.29.0-pre-0.30.0) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'OUT'
path /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000/imp.sqlite
sizeBytes 73728
lastMigration 0002_tokens
impVersion 0.29.0
createdAt 2026-10-08T12:00:00Z
integrity wrong # of entries in index sqlite_autoindex_imps_1
image ghcr.io/zgeoff/imp:0.29.0
copy: /root/imp-db-backups/imp-0.29.0-pre-0.30.0-20261008T120000 (73728 bytes, mode 600)
OUT
  diff /dev/null "$tree/err"
  diff "$tree/calls-expected" "$tree/calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_exits_1_with_dockers_error_when_imp_host_is_not_running() {
  local remote status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  remote="$(
    cat << 'REMOTE'
set -euo pipefail
umask 077
nix() { command nix --extra-experimental-features "nix-command flakes" "$@"; }
static=$(nix build --no-link --print-out-paths nixpkgs#pkgsStatic.sqlite.bin)/bin/sqlite3
sqlite=$(nix build --no-link --print-out-paths nixpkgs#sqlite.bin)/bin/sqlite3
mkdir -p -m 0700 /root/imp-db-backups
dir=/root/imp-db-backups/$1-$(date -u +%Y%m%dT%H%M%S)
mkdir -m 0700 "$dir"
work=$(docker exec imp-host sh -c "umask 077; mktemp -d /tmp/impd-db-copy.XXXXXX")
case $work in /tmp/impd-db-copy.??????) ;; *) echo "unexpected work dir: $work" >&2; exit 1 ;; esac
trap "docker exec imp-host rm -rf -- \"$work\"" EXIT
docker cp "$static" "imp-host:$work/sqlite3"
docker exec imp-host sh -c "umask 077; \"\$1/sqlite3\" /var/lib/imp/db/imp.sqlite \"VACUUM INTO '\$1/imp.sqlite'\"" _ "$work"
docker cp "imp-host:$work/imp.sqlite" "$dir/imp.sqlite"
chmod 0600 "$dir/imp.sqlite"
integrity=$("$sqlite" "$dir/imp.sqlite" "PRAGMA integrity_check;")
migration=$("$sqlite" "$dir/imp.sqlite" "SELECT name FROM kysely_migration ORDER BY name DESC LIMIT 1;")
version=$(docker exec imp-host imp info | sed -n "s/^version *//p")
image=$(docker inspect imp-host --format "{{.Config.Image}}")
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
size=$(stat -c %s "$dir/imp.sqlite")
# the field names match `imp db copy --json` (imp #171); impd cannot know the image, so cloud adds it
printf "path %s\nsizeBytes %s\nlastMigration %s\nimpVersion %s\ncreatedAt %s\nintegrity %s\nimage %s\n" \
  "$dir/imp.sqlite" "$size" "$migration" "$version" "$created" "$integrity" "$image" > "$dir/COPY-INFO"
cat "$dir/COPY-INFO"
echo "copy: $dir ($(stat -c "%s bytes, mode %a" "$dir/imp.sqlite"))"
test "$integrity" = ok
REMOTE
  )"
  jq -cn --arg command "bash -c $(printf '%q' "$remote") _ imp-0.29.0-pre-0.30.0" \
    '["ssh","-o","BatchMode=yes","root@geoffcloud",$command]' > "$tree/calls-expected"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_COPY_FAIL=imp-host-stopped bash copy-impd-db.sh imp-0.29.0-pre-0.30.0) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'Error response from daemon: container 4f6c0a2e9d1b7c4063034ef54c9cbfed806abcb7aee937d33c352266ea8718f6 is not running'
  diff "$tree/calls-expected" "$tree/calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_with_ssh_exit_255_when_the_host_refuses_the_connection() {
  local remote status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  remote="$(
    cat << 'REMOTE'
set -euo pipefail
umask 077
nix() { command nix --extra-experimental-features "nix-command flakes" "$@"; }
static=$(nix build --no-link --print-out-paths nixpkgs#pkgsStatic.sqlite.bin)/bin/sqlite3
sqlite=$(nix build --no-link --print-out-paths nixpkgs#sqlite.bin)/bin/sqlite3
mkdir -p -m 0700 /root/imp-db-backups
dir=/root/imp-db-backups/$1-$(date -u +%Y%m%dT%H%M%S)
mkdir -m 0700 "$dir"
work=$(docker exec imp-host sh -c "umask 077; mktemp -d /tmp/impd-db-copy.XXXXXX")
case $work in /tmp/impd-db-copy.??????) ;; *) echo "unexpected work dir: $work" >&2; exit 1 ;; esac
trap "docker exec imp-host rm -rf -- \"$work\"" EXIT
docker cp "$static" "imp-host:$work/sqlite3"
docker exec imp-host sh -c "umask 077; \"\$1/sqlite3\" /var/lib/imp/db/imp.sqlite \"VACUUM INTO '\$1/imp.sqlite'\"" _ "$work"
docker cp "imp-host:$work/imp.sqlite" "$dir/imp.sqlite"
chmod 0600 "$dir/imp.sqlite"
integrity=$("$sqlite" "$dir/imp.sqlite" "PRAGMA integrity_check;")
migration=$("$sqlite" "$dir/imp.sqlite" "SELECT name FROM kysely_migration ORDER BY name DESC LIMIT 1;")
version=$(docker exec imp-host imp info | sed -n "s/^version *//p")
image=$(docker inspect imp-host --format "{{.Config.Image}}")
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
size=$(stat -c %s "$dir/imp.sqlite")
# the field names match `imp db copy --json` (imp #171); impd cannot know the image, so cloud adds it
printf "path %s\nsizeBytes %s\nlastMigration %s\nimpVersion %s\ncreatedAt %s\nintegrity %s\nimage %s\n" \
  "$dir/imp.sqlite" "$size" "$migration" "$version" "$created" "$integrity" "$image" > "$dir/COPY-INFO"
cat "$dir/COPY-INFO"
echo "copy: $dir ($(stat -c "%s bytes, mode %a" "$dir/imp.sqlite"))"
test "$integrity" = ok
REMOTE
  )"
  jq -cn --arg command "bash -c $(printf '%q' "$remote") _ imp-0.29.0-pre-0.30.0" \
    '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1",$command]' > "$tree/calls-expected"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_SSH_PASS=1 IMPD_DB_HOST=ssh://root@127.0.0.1:1 bash copy-impd-db.sh imp-0.29.0-pre-0.30.0) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff "$tree/calls-expected" "$tree/calls"
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_stops_with_exit_1_and_its_usage_before_any_call_when_no_label_is_given() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash copy-impd-db.sh) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'copy-impd-db.sh: line 15: 1: usage: copy-impd-db.sh <label>, such as imp-0.29.0-pre-0.30.0'
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_with_exit_1_before_any_call_when_the_label_holds_another_character() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud bash copy-impd-db.sh '../imp 0.29') \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "the label may hold only letters, digits, '.', '_' and '-'"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Runtime every case needs: the script in <tree>, the ssh stand-in with fail-closed
# stand-ins for the other remote tools in <tree>/bin, checked so no call can reach a real
# remote tool, the empty call log, and the HOME and TMPDIR the script runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  cp "$(dirname "${BASH_SOURCE[0]}")/copy-impd-db.sh" "$tree/"
  create_stub_impd_db_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
