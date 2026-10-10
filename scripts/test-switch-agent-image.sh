#!/usr/bin/env bash
# Test for switch-agent-image.sh: against an atc config file in the case tree, never the live one,
# it backs the file up under a name that carries the UTC time and the image, sets the cloud
# target's image and guestATC and changes nothing else, keeps the file's mode 600, and prints the
# restart command without running it. It leaves a config that already names the image alone, and
# refuses an image the host lacks, a config without a cloud target and a missing config. imp is the
# create-stub-imp.sh stand-in, and date reads a fixed instant through create-stub-date.sh.
#
#   bash scripts/test-switch-agent-image.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/test-lib/run-cases.sh"
source "$scripts/test-lib/create-stub-imp.sh"
source "$scripts/test-lib/create-stub-date.sh"

script="$scripts/switch-agent-image.sh"

# setup_test <tree>: the imp and date stand-ins in <tree>/bin, a home with an empty
# .config/atc folder, and a temp folder
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home/.config/atc" "$tree/tmp"
  create_stub_imp "$tree/bin"
  create_stub_date "$tree/bin"
}

it_switches_the_cloud_target_after_a_backup() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-14d3c9d","digest":"imp-build-1"},{"name":"agent-abc1234","digest":"imp-build-2"}],"imps":[]}' > "$tree/imp-state.json"
  cat > "$tree/home/.config/atc/config.json" << 'EOF'
{
  "port": 8415,
  "targets": {
    "local": { "provider": "local" },
    "cloud": { "provider": "imp", "image": "agent-14d3c9d", "guestATC": "/usr/local/bin/atc", "host": "geoffcloud" }
  }
}
EOF
  chmod 600 "$tree/home/.config/atc/config.json"
  cp -p "$tree/home/.config/atc/config.json" "$tree/before"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_NOW=2026-10-10T05:06:07Z \
    bash "$script" agent-abc1234 "$tree/home/.config/atc/config.json" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << EOF
backed up $tree/home/.config/atc/config.json to $tree/home/.config/atc/config.json.bak-20261010T050607Z-pre-agent-abc1234
set targets.cloud.image to agent-abc1234 (was agent-14d3c9d)
the daemon reads its targets at startup: restart it when no session needs it, with
  systemctl --user restart atc-daemon.service
EOF
  diff /dev/null "$tree/err"
  cmp "$tree/before" "$tree/home/.config/atc/config.json.bak-20261010T050607Z-pre-agent-abc1234"
  diff - "$tree/home/.config/atc/config.json" << 'EOF'
{
  "port": 8415,
  "targets": {
    "local": {
      "provider": "local"
    },
    "cloud": {
      "provider": "imp",
      "image": "agent-abc1234",
      "guestATC": "/usr/local/bin/atc",
      "host": "geoffcloud"
    }
  }
}
EOF
  diff - <(stat -c %a "$tree/home/.config/atc/config.json") <<< 600
  diff - <(stat -c %a "$tree/home/.config/atc/config.json.bak-20261010T050607Z-pre-agent-abc1234") <<< 600
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_switches_the_config_in_its_home_by_default() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-abc1234","digest":"imp-build-2"}],"imps":[]}' > "$tree/imp-state.json"
  echo '{"targets":{"cloud":{"provider":"imp","image":"agent-14d3c9d"}}}' > "$tree/home/.config/atc/config.json"
  chmod 600 "$tree/home/.config/atc/config.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_NOW=2026-10-10T05:06:07Z \
    bash "$script" agent-abc1234 > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(jq -c . "$tree/home/.config/atc/config.json") <<< '{"targets":{"cloud":{"provider":"imp","image":"agent-abc1234","guestATC":"/usr/local/bin/atc"}}}'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_leaves_a_config_that_already_names_the_image_alone() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-abc1234","digest":"imp-build-2"}],"imps":[]}' > "$tree/imp-state.json"
  echo '{"targets":{"cloud":{"provider":"imp","image":"agent-abc1234","guestATC":"/usr/local/bin/atc"}}}' > "$tree/home/.config/atc/config.json"
  cp -p "$tree/home/.config/atc/config.json" "$tree/before"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_NOW=2026-10-10T05:06:07Z \
    bash "$script" agent-abc1234 "$tree/home/.config/atc/config.json" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'the cloud target already runs agent-abc1234'
  diff /dev/null "$tree/err"
  cmp "$tree/before" "$tree/home/.config/atc/config.json"
  diff - <(ls "$tree/home/.config/atc") <<< 'config.json'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_sets_guest_atc_when_the_config_names_the_image_without_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-abc1234","digest":"imp-build-2"}],"imps":[]}' > "$tree/imp-state.json"
  echo '{"targets":{"cloud":{"provider":"imp","image":"agent-abc1234","guestATC":"/missing/atc"}}}' > "$tree/home/.config/atc/config.json"
  chmod 600 "$tree/home/.config/atc/config.json"
  cp -p "$tree/home/.config/atc/config.json" "$tree/before"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_NOW=2026-10-10T05:06:07Z \
    bash "$script" agent-abc1234 "$tree/home/.config/atc/config.json" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << EOF
backed up $tree/home/.config/atc/config.json to $tree/home/.config/atc/config.json.bak-20261010T050607Z-pre-agent-abc1234
set targets.cloud.image to agent-abc1234 (was agent-abc1234)
the daemon reads its targets at startup: restart it when no session needs it, with
  systemctl --user restart atc-daemon.service
EOF
  diff /dev/null "$tree/err"
  cmp "$tree/before" "$tree/home/.config/atc/config.json.bak-20261010T050607Z-pre-agent-abc1234"
  diff - <(jq -c . "$tree/home/.config/atc/config.json") <<< '{"targets":{"cloud":{"provider":"imp","image":"agent-abc1234","guestATC":"/usr/local/bin/atc"}}}'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_refuses_an_image_the_host_lacks() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-14d3c9d","digest":"imp-build-1"}],"imps":[]}' > "$tree/imp-state.json"
  echo '{"targets":{"cloud":{"provider":"imp","image":"agent-14d3c9d"}}}' > "$tree/home/.config/atc/config.json"
  cp -p "$tree/home/.config/atc/config.json" "$tree/before"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_NOW=2026-10-10T05:06:07Z \
    bash "$script" agent-abc1234 "$tree/home/.config/atc/config.json" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the imp host has no image agent-abc1234: build it with scripts/build-agent-image.sh first'
  cmp "$tree/before" "$tree/home/.config/atc/config.json"
  diff - <(ls "$tree/home/.config/atc") <<< 'config.json'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_config_without_a_cloud_target() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"images":[{"name":"agent-abc1234","digest":"imp-build-2"}],"imps":[]}' > "$tree/imp-state.json"
  echo '{"targets":{"local":{"provider":"local"}}}' > "$tree/home/.config/atc/config.json"
  cp -p "$tree/home/.config/atc/config.json" "$tree/before"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_NOW=2026-10-10T05:06:07Z \
    bash "$script" agent-abc1234 "$tree/home/.config/atc/config.json" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/home/.config/atc/config.json has no targets.cloud object"
  cmp "$tree/before" "$tree/home/.config/atc/config.json"
  diff - <(ls "$tree/home/.config/atc") <<< 'config.json'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_missing_config() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_NOW=2026-10-10T05:06:07Z \
    bash "$script" agent-abc1234 "$tree/home/.config/atc/config.json" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/home/.config/atc/config.json has no targets.cloud object"
  diff /dev/null <(ls "$tree/home/.config/atc")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_prints_its_usage_without_an_image() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" STUB_NOW=2026-10-10T05:06:07Z \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: switch-agent-image.sh <image> [<atc config file>]'
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

run_cases
