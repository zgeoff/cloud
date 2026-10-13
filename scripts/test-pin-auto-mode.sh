#!/usr/bin/env bash
# Test for pin-auto-mode.sh: in a case tree that holds images/agent/Dockerfile, it changes the
# AUTO_MODE_VERSION and AUTO_MODE_SHA256 pins to a release's version and its npm tarball's sha256,
# and nothing else. It leaves a pin that already matches, or a newer one, alone, and refuses a
# tarball that does not match its integrity, a tarball of another version, a sum that differs for
# the pinned version, a Dockerfile without exactly one of each pin, and a bad version or integrity.
# Each case packs a real tarball with tar and takes its integrity from openssl, as npm writes it,
# then runs the script under `env -i` from the case tree's repository.
#
#   bash scripts/test-pin-auto-mode.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pin-auto-mode.sh"

# setup_test <tree>: the repository folder the script runs in, with images/agent and no
# Dockerfile, the folder each case packs its tarball from, and the home and temp folders the
# script runs with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/repo/images/agent" "$tree/pack/package" "$tree/home" "$tree/tmp"
}

it_pins_a_new_version_and_its_sum() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG OP_VERSION=2.40.0
ARG AUTO_MODE_VERSION=0.17.0
ARG AUTO_MODE_SHA256=0a9fa7045739d19f9bc7a18602a6b1b986732dffcb12e853de6f2be715c70d79
RUN echo "${AUTO_MODE_SHA256}  /tmp/auto-mode.tgz" | sha256sum -c -
ARG GITLEAKS_VERSION=8.30.1
EOF
  echo '{"name":"auto-mode","version":"0.19.3"}' > "$tree/pack/package/package.json"
  tar -czf "$tree/auto-mode.tgz" -C "$tree/pack" package
  integrity="sha512-$(openssl dgst -sha512 -binary "$tree/auto-mode.tgz" | base64 -w0)"
  sum="$(sha256sum "$tree/auto-mode.tgz" | cut -d' ' -f1)"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.19.3 "$tree/auto-mode.tgz" "$integrity") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/repo/images/agent/Dockerfile" << EOF
ARG OP_VERSION=2.40.0
ARG AUTO_MODE_VERSION=0.19.3
ARG AUTO_MODE_SHA256=$sum
RUN echo "\${AUTO_MODE_SHA256}  /tmp/auto-mode.tgz" | sha256sum -c -
ARG GITLEAKS_VERSION=8.30.1
EOF
  diff - "$tree/out" <<< "pinned auto-mode 0.19.3: $sum"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_leaves_a_pin_that_already_matches_alone() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"name":"auto-mode","version":"0.19.3"}' > "$tree/pack/package/package.json"
  tar -czf "$tree/auto-mode.tgz" -C "$tree/pack" package
  integrity="sha512-$(openssl dgst -sha512 -binary "$tree/auto-mode.tgz" | base64 -w0)"
  sum="$(sha256sum "$tree/auto-mode.tgz" | cut -d' ' -f1)"
  printf 'ARG AUTO_MODE_VERSION=0.19.3\nARG AUTO_MODE_SHA256=%s\n' "$sum" > "$tree/repo/images/agent/Dockerfile"
  cp "$tree/repo/images/agent/Dockerfile" "$tree/before"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.19.3 "$tree/auto-mode.tgz" "$integrity") > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff - "$tree/out" <<< 'auto-mode 0.19.3 is already pinned'
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
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG AUTO_MODE_VERSION=0.20.0
ARG AUTO_MODE_SHA256=1111111111111111111111111111111111111111111111111111111111111111
EOF
  cp "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '{"name":"auto-mode","version":"0.19.3"}' > "$tree/pack/package/package.json"
  tar -czf "$tree/auto-mode.tgz" -C "$tree/pack" package
  integrity="sha512-$(openssl dgst -sha512 -binary "$tree/auto-mode.tgz" | base64 -w0)"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.19.3 "$tree/auto-mode.tgz" "$integrity") > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff - "$tree/out" <<< 'auto-mode 0.20.0 is pinned, which is newer than 0.19.3'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_refuses_another_sum_for_the_pinned_version() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG AUTO_MODE_VERSION=0.19.3
ARG AUTO_MODE_SHA256=1111111111111111111111111111111111111111111111111111111111111111
EOF
  cp "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '{"name":"auto-mode","version":"0.19.3"}' > "$tree/pack/package/package.json"
  tar -czf "$tree/auto-mode.tgz" -C "$tree/pack" package
  integrity="sha512-$(openssl dgst -sha512 -binary "$tree/auto-mode.tgz" | base64 -w0)"
  sum="$(sha256sum "$tree/auto-mode.tgz" | cut -d' ' -f1)"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.19.3 "$tree/auto-mode.tgz" "$integrity") > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "auto-mode 0.19.3 is pinned with sum 1111111111111111111111111111111111111111111111111111111111111111, but the tarball's is $sum"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_tarball_that_does_not_match_its_integrity() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG AUTO_MODE_VERSION=0.17.0
ARG AUTO_MODE_SHA256=1111111111111111111111111111111111111111111111111111111111111111
EOF
  cp "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '{"name":"auto-mode","version":"0.19.3"}' > "$tree/pack/package/package.json"
  tar -czf "$tree/auto-mode.tgz" -C "$tree/pack" package
  integrity="sha512-$(openssl dgst -sha512 -binary "$tree/auto-mode.tgz" | base64 -w0)"
  echo 'trailing bytes' >> "$tree/auto-mode.tgz"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.19.3 "$tree/auto-mode.tgz" "$integrity") > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "the tarball does not match $integrity"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_tarball_of_another_version() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG AUTO_MODE_VERSION=0.17.0
ARG AUTO_MODE_SHA256=1111111111111111111111111111111111111111111111111111111111111111
EOF
  cp "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '{"name":"auto-mode","version":"0.19.2"}' > "$tree/pack/package/package.json"
  tar -czf "$tree/auto-mode.tgz" -C "$tree/pack" package
  integrity="sha512-$(openssl dgst -sha512 -binary "$tree/auto-mode.tgz" | base64 -w0)"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.19.3 "$tree/auto-mode.tgz" "$integrity") > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the tarball holds auto-mode 0.19.2, not 0.19.3'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_dockerfile_without_an_auto_mode_version_pin() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'ARG AUTO_MODE_SHA256=1111111111111111111111111111111111111111111111111111111111111111' > "$tree/repo/images/agent/Dockerfile"
  echo '{"name":"auto-mode","version":"0.19.3"}' > "$tree/pack/package/package.json"
  tar -czf "$tree/auto-mode.tgz" -C "$tree/pack" package
  integrity="sha512-$(openssl dgst -sha512 -binary "$tree/auto-mode.tgz" | base64 -w0)"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.19.3 "$tree/auto-mode.tgz" "$integrity") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/repo/images/agent/Dockerfile" <<< 'ARG AUTO_MODE_SHA256=1111111111111111111111111111111111111111111111111111111111111111'
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'images/agent/Dockerfile has 0 ARG AUTO_MODE_VERSION= lines, want 1'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_dockerfile_with_two_auto_mode_sha256_pins() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
ARG AUTO_MODE_VERSION=0.17.0
ARG AUTO_MODE_SHA256=1111111111111111111111111111111111111111111111111111111111111111
ARG AUTO_MODE_SHA256=2222222222222222222222222222222222222222222222222222222222222222
EOF
  cp "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '{"name":"auto-mode","version":"0.19.3"}' > "$tree/pack/package/package.json"
  tar -czf "$tree/auto-mode.tgz" -C "$tree/pack" package
  integrity="sha512-$(openssl dgst -sha512 -binary "$tree/auto-mode.tgz" | base64 -w0)"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.19.3 "$tree/auto-mode.tgz" "$integrity") > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'images/agent/Dockerfile has 2 ARG AUTO_MODE_SHA256= lines, want 1'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_version_that_is_not_a_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.19.3-rc.1 "$tree/auto-mode.tgz" sha512-x) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "not a release version: '0.19.3-rc.1'"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_refuses_an_integrity_that_is_not_sha512() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" bash "$script" 0.19.3 "$tree/auto-mode.tgz" sha1-CO9z/T8qyTDy8QmgjOvz7kAppJw=) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "not a sha512 integrity: 'sha1-CO9z/T8qyTDy8QmgjOvz7kAppJw='"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

run_cases
