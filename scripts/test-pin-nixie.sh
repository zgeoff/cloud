#!/usr/bin/env bash
# Test for pin-nixie.sh: in a case tree that holds infra/Pulumi.prod.yaml, it changes the nixie and
# nixie-web image pins to a release's tag and the digests its notes list under `## Images`, and
# nothing else. It keeps a pin that already holds the release or a newer one, and refuses, with the
# config unchanged, a pin that holds the release with another digest and notes without one of the
# two images. Each case runs the script under `env -i` from the case tree's repository.
#
#   bash scripts/test-pin-nixie.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pin-nixie.sh"

# setup_test <tree>: the repository folder the script runs in, with infra/ and no config, and the
# home and temp folders the script runs with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/repo/infra" "$tree/home" "$tree/tmp"
}

it_pins_both_images_and_leaves_the_other_images_alone() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/infra/Pulumi.prod.yaml" << 'EOF'
config:
  geoff-cloud:atcGateway:
    image: ghcr.io/zgeoff/atc-gateway:2.27.0@sha256:b53896a326e7c407167a5973736526b68ca6f30500d00558f1a7350869d91867
  geoff-cloud:nixie:
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:1111111111111111111111111111111111111111111111111111111111111111
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:2222222222222222222222222222222222222222222222222222222222222222
EOF
  cat > "$tree/notes.md" << 'EOF'
## [0.7.1](https://github.com/zgeoff/nixie/compare/v0.7.0...v0.7.1) (2026-10-13)

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:5555555555555555555555555555555555555555555555555555555555555555`
- `ghcr.io/zgeoff/nixie@sha256:3333333333333333333333333333333333333333333333333333333333333333`
- `ghcr.io/zgeoff/nixie-web@sha256:4444444444444444444444444444444444444444444444444444444444444444`

## Other

- `ghcr.io/zgeoff/nixie@sha256:6666666666666666666666666666666666666666666666666666666666666666`
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.7.1 "$tree/notes.md") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/repo/infra/Pulumi.prod.yaml" << 'EOF'
config:
  geoff-cloud:atcGateway:
    image: ghcr.io/zgeoff/atc-gateway:2.27.0@sha256:b53896a326e7c407167a5973736526b68ca6f30500d00558f1a7350869d91867
  geoff-cloud:nixie:
    image: ghcr.io/zgeoff/nixie:0.7.1@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.1@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  diff - "$tree/out" << 'EOF'
pinned nixie 0.7.1: sha256:3333333333333333333333333333333333333333333333333333333333333333
pinned nixie-web 0.7.1: sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_leaves_a_release_that_is_already_pinned_alone() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.1@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.1@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  cp -p "$tree/repo/infra/Pulumi.prod.yaml" "$tree/before"
  cat > "$tree/notes.md" << 'EOF'
## Images

- `ghcr.io/zgeoff/nixie@sha256:3333333333333333333333333333333333333333333333333333333333333333`
- `ghcr.io/zgeoff/nixie-web@sha256:4444444444444444444444444444444444444444444444444444444444444444`
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.7.1 "$tree/notes.md") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/infra/Pulumi.prod.yaml"
  diff - "$tree/out" << 'EOF'
nixie 0.7.1 is already pinned
nixie-web 0.7.1 is already pinned
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_leaves_a_newer_pin_alone() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.8.0@sha256:1111111111111111111111111111111111111111111111111111111111111111
    webImage: ghcr.io/zgeoff/nixie-web:0.8.0@sha256:2222222222222222222222222222222222222222222222222222222222222222
EOF
  cp -p "$tree/repo/infra/Pulumi.prod.yaml" "$tree/before"
  cat > "$tree/notes.md" << 'EOF'
## Images

- `ghcr.io/zgeoff/nixie@sha256:3333333333333333333333333333333333333333333333333333333333333333`
- `ghcr.io/zgeoff/nixie-web@sha256:4444444444444444444444444444444444444444444444444444444444444444`
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.7.1 "$tree/notes.md") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/infra/Pulumi.prod.yaml"
  diff - "$tree/out" << 'EOF'
nixie 0.8.0 is pinned, which is newer than 0.7.1
nixie-web 0.8.0 is pinned, which is newer than 0.7.1
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_refuses_the_release_pinned_with_another_digest_without_writing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:1111111111111111111111111111111111111111111111111111111111111111
    webImage: ghcr.io/zgeoff/nixie-web:0.7.1@sha256:2222222222222222222222222222222222222222222222222222222222222222
EOF
  cp -p "$tree/repo/infra/Pulumi.prod.yaml" "$tree/before"
  cat > "$tree/notes.md" << 'EOF'
## Images

- `ghcr.io/zgeoff/nixie@sha256:3333333333333333333333333333333333333333333333333333333333333333`
- `ghcr.io/zgeoff/nixie-web@sha256:4444444444444444444444444444444444444444444444444444444444444444`
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.7.1 "$tree/notes.md") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/infra/Pulumi.prod.yaml"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'nixie-web 0.7.1 is pinned with sha256:2222222222222222222222222222222222222222222222222222222222222222, but the release notes list sha256:4444444444444444444444444444444444444444444444444444444444444444'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_notes_without_the_web_image_without_writing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:1111111111111111111111111111111111111111111111111111111111111111
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:2222222222222222222222222222222222222222222222222222222222222222
EOF
  cp -p "$tree/repo/infra/Pulumi.prod.yaml" "$tree/before"
  cat > "$tree/notes.md" << 'EOF'
## Images

- `ghcr.io/zgeoff/nixie@sha256:3333333333333333333333333333333333333333333333333333333333333333`

## Other

- `ghcr.io/zgeoff/nixie-web@sha256:4444444444444444444444444444444444444444444444444444444444444444`
EOF

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.7.1 "$tree/notes.md") > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/infra/Pulumi.prod.yaml"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the release notes list 0 ghcr.io/zgeoff/nixie-web digests under ## Images, want 1'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_prints_its_usage_without_a_notes_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.7.1) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: pin-nixie.sh <version> <release notes file>'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

run_cases
