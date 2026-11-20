#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for the agent image's boot service, sbin/setup-swap, through its --size-for
# mode: the swapfile size it picks for an amount of free space is at most 2048 MiB, at most a
# quarter of the free space, and leaves 2048 MiB free, and it makes none under 256 MiB, across every
# free space up to 64 GiB. It refuses
# a free space that is not a whole number and an unknown argument. Each case runs the script with
# `sh` under `env -i`, so CI runs it with dash, the guest's /bin/sh; the sweep up to 64 GiB sources
# the script's sizing function into one such shell. The boot mode writes /swapfile
# and runs swapon as root, so check-agent-image.ts checks it in a fresh imp instead.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  script="$BATS_TEST_DIRNAME/sbin/setup-swap"
}

teardown() {
  stop_timeout_watchdog
}

@test "it picks 2048 mib for the free space of a 32 gib imp" {
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 31457280 > "$tree/out" 2> "$tree/err"

  diff - "$tree/out" <<< 2048
  diff /dev/null "$tree/err"
}

@test "it picks a quarter of the free space when that is under 2048 mib" {
  # 6144 MiB free
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 6291456 > "$tree/out" 2> "$tree/err"

  diff - "$tree/out" <<< 1536
  diff /dev/null "$tree/err"
}

@test "it leaves 2048 mib free when that is the tightest bound" {
  # 2560 MiB free: a quarter is 640 MiB, and 512 MiB leaves 2048 MiB
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 2621440 > "$tree/out" 2> "$tree/err"

  diff - "$tree/out" <<< 512
  diff /dev/null "$tree/err"
}

@test "it picks 256 mib at the floor" {
  # 2304 MiB free: 256 MiB leaves 2048 MiB
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 2359296 > "$tree/out" 2> "$tree/err"

  diff - "$tree/out" <<< 256
  diff /dev/null "$tree/err"
}

@test "it picks no swapfile under the floor" {
  # 2303 MiB free: 255 MiB would leave 2048 MiB
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 2358272 > "$tree/out" 2> "$tree/err"

  diff - "$tree/out" <<< 0
  diff /dev/null "$tree/err"
}

@test "it picks no swapfile when less than 2048 mib is free" {
  # 1024 MiB free
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 1048576 > "$tree/out" 2> "$tree/err"

  diff - "$tree/out" <<< 0
  diff /dev/null "$tree/err"
}

@test "it keeps 2048 mib free for every free space up to 64 gib" {
  # the script's settings and sizing function, the lines from `set -eu` to its argument parse, so
  # one shell sizes all 4131 free spaces instead of starting sh once for each
  sed -n '/^set -eu$/,/^case /p' "$script" | sed '$d' > "$tree/size-for.sh"

  # every 16 MiB from 0 to 64 GiB, plus each MiB around the floor and the 2048 MiB cap
  # shellcheck disable=SC2016,SC2046
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh -c '
    . "$1"
    shift
    for free in "$@"; do
      printf "%s " "$free"
      size_for $((free * 1024))
    done
  ' sh "$tree/size-for.sh" $(seq 0 16 65536) $(seq 2296 2312) $(seq 8184 8200) > "$tree/sizes"

  # a violation is a size off the bounds, a skip when 256 MiB fits every bound, or a swapfile when
  # it does not
  awk '!(($2 == 0 && $1 < 2304) || ($2 >= 256 && $2 <= 2048 && $2 <= int($1 / 4) && $1 - $2 >= 2048))' "$tree/sizes" > "$tree/violations"
  diff /dev/null "$tree/violations"
  assert_equal "$(wc -l < "$tree/sizes")" 4131
}

@test "it refuses a free space that is not a whole number" {
  local status=0
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size-for 2g > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 2

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'setup-swap: --size-for takes the free space in KiB, a whole number'
}

@test "it refuses an unknown argument" {
  local status=0
  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$script" --size 2048 > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 2

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: setup-swap [--size-for <free KiB>]'
}
