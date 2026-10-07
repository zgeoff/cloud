#!/usr/bin/env bash
# Test for normalize-restic-output.sh: normalize_restic_output masks the parts of restic's
# output that change from run to run and leaves every other byte alone.
#
#   bash scripts/test-lib/test-normalize-restic-output.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/normalize-restic-output.sh"

it_masks_a_snapshot_ID_at_the_start_of_a_row_and_after_snapshot() {
  diff - <(normalize_restic_output << 'EOF'
a1b2c3d4  2020-01-06 10:00:00  atc-gateway  atc-gateway  /tmp/a
snapshot 0f1e2d3c saved
EOF
  ) << 'EOF'
ID  2020-01-06 10:00:00  atc-gateway  atc-gateway  /tmp/a
snapshot ID saved
EOF
}

it_leaves_hex_that_is_not_a_snapshot_ID_alone() {
  diff - <(normalize_restic_output << 'EOF'
deadbeef saved
abcdefg1  not hex
  a1b2c3d4  indented
a1b2c3d4e5  too long
EOF
  ) << 'EOF'
deadbeef saved
abcdefg1  not hex
  a1b2c3d4  indented
a1b2c3d4e5  too long
EOF
}

it_masks_a_time_from_2021_on_with_or_without_fractional_seconds() {
  diff - <(normalize_restic_output << 'EOF'
at 2026-10-07 12:34:56.123456789 +0000 UTC
at 2021-01-01 00:00:00 and 2099-12-31 23:59:59.5
EOF
  ) << 'EOF'
at NOW +0000 UTC
at NOW and NOW
EOF
}

it_keeps_a_2020_time_and_drops_only_zero_fractional_seconds() {
  diff - <(normalize_restic_output << 'EOF'
at 2020-01-06 10:00:00.000000000 +0000 UTC
at 2020-01-06 11:00:00.5 +0000 UTC
at 2020-01-06 12:00:00 +0000 UTC
EOF
  ) << 'EOF'
at 2020-01-06 10:00:00 +0000 UTC
at 2020-01-06 11:00:00.5 +0000 UTC
at 2020-01-06 12:00:00 +0000 UTC
EOF
}

it_masks_sizes_in_bytes_KiB_and_MiB() {
  diff - <(normalize_restic_output << 'EOF'
Added to the repository: 1.5 MiB (700 B stored)
remaining:             5 blobs / 20.000 KiB
total: 3 GiB
EOF
  ) << 'EOF'
Added to the repository: SIZE (SIZE stored)
remaining:             5 blobs / SIZE
total: 3 GiB
EOF
}

it_masks_a_duration_after_in_and_a_progress_lines_elapsed_time() {
  diff - <(normalize_restic_output << 'EOF'
Summary: Restored 2 files/dirs (12 B) in 0:01
processed 1 files, 0 B in 12:03
[0:00] 100.00%  1 / 1 files deleted
[10:42] 100.00%  4 / 4 indexes processed
EOF
  ) << 'EOF'
Summary: Restored 2 files/dirs (SIZE) in T
processed 1 files, SIZE in T
[T] 100.00%  1 / 1 files deleted
[T] 100.00%  4 / 4 indexes processed
EOF
}

it_masks_the_restores_temp_directory() {
  diff - <(normalize_restic_output << 'EOF'
restoring snapshot 0f1e2d3c of [/tmp/snap] at 2020-01-06 10:00:00.000000000 +0000 UTC by @atc-gateway to /tmp/tmp.Ab12Cd
EOF
  ) << 'EOF'
restoring snapshot ID of [/tmp/snap] at 2020-01-06 10:00:00 +0000 UTC by @atc-gateway to /tmp/tmp.X
EOF
}

run_cases
