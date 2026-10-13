#!/usr/bin/env bash
# Test for find-nixie-release-flags.sh: from release notes shaped like nixie's, it flags
# `migrations` when the target or a release between holds a migration, or lacks the section, and
# `sandbox-images-changed` when the images other than nixie and nixie-web differ between the
# pinned release and the target. It prints nothing for a bump with neither.
#
#   bash scripts/test-find-nixie-release-flags.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/test-lib/run-cases.sh"

script="$scripts/find-nixie-release-flags.sh"

# setup_test <tree>: the home and temp folders the script runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp"
}

it_prints_nothing_for_a_release_without_migrations_or_new_sandbox_images() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/pinned.md" << 'EOF'
## [0.7.0](https://github.com/zgeoff/nixie/compare/v0.6.2...v0.7.0) (2026-10-13)

<!-- nixie: migrations -->
## Migrations

This release adds no migration since v0.6.2.

## Images

- `ghcr.io/zgeoff/nixie-conversation@sha256:1111111111111111111111111111111111111111111111111111111111111111`
- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
- `ghcr.io/zgeoff/nixie@sha256:3333333333333333333333333333333333333333333333333333333333333333`
- `ghcr.io/zgeoff/nixie-web@sha256:4444444444444444444444444444444444444444444444444444444444444444`
EOF
  cat > "$tree/target.md" << 'EOF'
## [0.7.1](https://github.com/zgeoff/nixie/compare/v0.7.0...v0.7.1) (2026-10-14)

<!-- nixie: migrations -->
## Migrations

This release adds no migration since v0.7.0.

## Images

- `ghcr.io/zgeoff/nixie-conversation@sha256:1111111111111111111111111111111111111111111111111111111111111111`
- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
- `ghcr.io/zgeoff/nixie@sha256:5555555555555555555555555555555555555555555555555555555555555555`
- `ghcr.io/zgeoff/nixie-web@sha256:6666666666666666666666666666666666666666666666666666666666666666`
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/pinned.md" "$tree/target.md" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_flags_migrations_that_the_target_adds() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/pinned.md" << 'EOF'
## Migrations

This release adds no migration since v0.5.0.

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
- `ghcr.io/zgeoff/nixie@sha256:3333333333333333333333333333333333333333333333333333333333333333`
EOF
  cat > "$tree/target.md" << 'EOF'
## Migrations

The migrations this release adds since v0.5.0, and whether v0.5.0 can read the schema each leaves.

| Version | Migration | Readable by v0.5.0 |
| ------- | --------- | ---------------------- |
| 7 | create the memory projections | yes |

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
- `ghcr.io/zgeoff/nixie@sha256:5555555555555555555555555555555555555555555555555555555555555555`
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/pinned.md" "$tree/target.md" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'migrations'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_flags_migrations_that_only_a_release_between_adds() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/pinned.md" << 'EOF'
## Migrations

This release adds no migration since v0.5.0.

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
EOF
  cat > "$tree/between.md" << 'EOF'
## Migrations

The migrations this release adds since v0.6.0, and whether v0.6.0 can read the schema each leaves.

| Version | Migration | Readable by v0.6.0 |
| ------- | --------- | ---------------------- |
| 8 | create the memory writer projection | yes |

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
EOF
  cat > "$tree/target.md" << 'EOF'
## Migrations

This release adds no migration since v0.6.1.

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/pinned.md" "$tree/target.md" "$tree/between.md" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'migrations'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_flags_migrations_when_a_release_lacks_the_section() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/pinned.md" << 'EOF'
## Migrations

This release adds no migration since v0.5.0.

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
EOF
  cat > "$tree/target.md" << 'EOF'
## [0.6.1](https://github.com/zgeoff/nixie/compare/v0.6.0...v0.6.1) (2026-10-12)

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/pinned.md" "$tree/target.md" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'migrations'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_flags_a_changed_sandbox_image() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/pinned.md" << 'EOF'
## Migrations

This release adds no migration since v0.6.1.

## Images

- `ghcr.io/zgeoff/nixie-conversation@sha256:1111111111111111111111111111111111111111111111111111111111111111`
- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
- `ghcr.io/zgeoff/nixie@sha256:3333333333333333333333333333333333333333333333333333333333333333`
EOF
  cat > "$tree/target.md" << 'EOF'
## Migrations

This release adds no migration since v0.6.2.

## Images

- `ghcr.io/zgeoff/nixie-conversation@sha256:1111111111111111111111111111111111111111111111111111111111111111`
- `ghcr.io/zgeoff/nixie-fetch@sha256:7777777777777777777777777777777777777777777777777777777777777777`
- `ghcr.io/zgeoff/nixie@sha256:3333333333333333333333333333333333333333333333333333333333333333`
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/pinned.md" "$tree/target.md" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'sandbox-images-changed'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_both_flags_for_a_release_with_both() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/pinned.md" << 'EOF'
## Migrations

This release adds no migration since v0.5.0.

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
EOF
  cat > "$tree/target.md" << 'EOF'
## Migrations

| Version | Migration | Readable by v0.5.0 |
| ------- | --------- | ---------------------- |
| 7 | create the memory projections | yes |

## Images

- `ghcr.io/zgeoff/nixie-conversation@sha256:1111111111111111111111111111111111111111111111111111111111111111`
- `ghcr.io/zgeoff/nixie-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222`
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/pinned.md" "$tree/target.md" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
migrations
sandbox-images-changed
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_its_usage_without_target_notes() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '## Migrations' > "$tree/pinned.md"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/pinned.md" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: find-nixie-release-flags.sh <pinned notes> <target notes> [<notes between>...]'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_flags_migrations_in_a_section_longer_than_a_pipe_buffer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/pinned.md" << 'EOF'
## Migrations

This release adds no migration since v0.6.2.
EOF
  {
    printf '## Migrations\n\n| Version | Migration |\n| ------- | --------- |\n'
    for i in $(seq 1000); do echo "| $i | create the projection of table $i and backfill it from the event log |"; done
  } > "$tree/target.md"

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/pinned.md" "$tree/target.md" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'migrations'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_flags_migrations_when_the_section_is_blank() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/pinned.md" << 'EOF'
## Migrations

This release adds no migration since v0.6.2.
EOF
  cat > "$tree/target.md" << 'EOF'
## Migrations



## Images
EOF

  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/pinned.md" "$tree/target.md" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'migrations'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

run_cases
