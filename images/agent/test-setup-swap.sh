#!/usr/bin/env bash
# Test for the agent image's boot service, sbin/setup-swap, through its --size-for
# mode: the swapfile size it picks for an amount of free space is at most 2048 MiB, at most a
# quarter of the free space, and leaves 2048 MiB free, and it makes none under 256 MiB, across every
# free space up to 64 GiB. It refuses
# a free space that is not a whole number and an unknown argument. Each case runs the script with
# `sh` under `env -i`, so CI runs it with dash, the guest's /bin/sh. The boot mode writes /swapfile
# and runs swapon as root, so check-agent-image.sh checks it in a fresh imp instead.
#
#   bash images/agent/test-setup-swap.sh
# shellcheck source-path=SCRIPTDIR/../../scripts
set -euo pipefail
umask 022
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/test-lib/run-cases.sh
source "$here/../../scripts/test-lib/run-cases.sh"

script="$here/sbin/setup-swap"

it_picks_2048_mib_for_the_free_space_of_a_32_gib_imp() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 31457280 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 2048
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_picks_a_quarter_of_the_free_space_when_that_is_under_2048_mib() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # 6144 MiB free
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 6291456 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 1536
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_leaves_2048_mib_free_when_that_is_the_tightest_bound() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # 2560 MiB free: a quarter is 640 MiB, and 512 MiB leaves 2048 MiB
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 2621440 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 512
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_picks_256_mib_at_the_floor() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # 2304 MiB free: 256 MiB leaves 2048 MiB
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 2359296 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 256
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_picks_no_swapfile_under_the_floor() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # 2303 MiB free: 255 MiB would leave 2048 MiB
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 2358272 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 0
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_picks_no_swapfile_when_less_than_2048_mib_is_free() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # 1024 MiB free
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 1048576 > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 0
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_keeps_2048_mib_free_for_every_free_space_up_to_64_gib() {
  local free size
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  # every 16 MiB from 0 to 64 GiB, plus each MiB around the floor and the 2048 MiB cap
  for free in $(seq 0 16 65536) $(seq 2296 2312) $(seq 8184 8200); do
    size=$(env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for $((free * 1024)))
    echo "$free $size" >> "$tree/sizes"
  done

  # a violation is a size off the bounds, a skip when 256 MiB fits every bound, or a swapfile when
  # it does not
  awk '!(($2 == 0 && $1 < 2304) || ($2 >= 256 && $2 <= 2048 && $2 <= int($1 / 4) && $1 - $2 >= 2048))' "$tree/sizes" > "$tree/violations"
  diff /dev/null "$tree/violations"
  [ "$(wc -l < "$tree/sizes")" = 4131 ] || {
    echo "$(wc -l < "$tree/sizes") sizes, want 4131" >&2
    exit 1
  }
}

it_refuses_a_free_space_that_is_not_a_whole_number() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 2g > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'setup-swap: --size-for takes the free space in KiB, a whole number'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_refuses_an_unknown_argument() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size 2048 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: setup-swap [--size-for <free KiB>]'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

run_cases
