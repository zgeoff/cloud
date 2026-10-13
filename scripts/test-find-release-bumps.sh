#!/usr/bin/env bash
# Test for find-release-bumps.sh: from a checkout's pins and the releases of zgeoff/atc, zgeoff/imp,
# zgeoff/nixie and zgeoff/auto-mode, it prints one line for each dependency with a pin older than its newest
# release, and nothing when every pin is current. It takes the highest X.Y.Z among the tags of the
# dependency's own form, and fails on a missing or doubled pin and on a repository with no
# release. gh is the create-stub-release-gh.sh stand-in.
#
#   bash scripts/test-find-release-bumps.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/test-lib/run-cases.sh"
source "$scripts/test-lib/create-stub-release-gh.sh"

script="$scripts/find-release-bumps.sh"

# setup_test <tree>: the gh stand-in in <tree>/bin, the home and temp folders the cases run with,
# and <tree>/seed, the empty checkout whose pins each case writes. It sets case_env, the
# environment the script runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/seed/images/agent" "$tree/seed/nixos/packages" \
    "$tree/seed/nixos/hosts/geoffcloud" "$tree/seed/deploy/atc-gateway" "$tree/seed/infra" \
    "$tree/releases/atc" "$tree/releases/imp" "$tree/releases/nixie" "$tree/releases/auto-mode"
  create_stub_release_gh "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree")
}

it_prints_nothing_when_every_pin_holds_its_newest_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.3.0
ARG AUTO_MODE_VERSION=0.19.3
EOF
  echo '  version = "4.3.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/deploy/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  echo '@zgeoff/atc@4.3.0' > "$tree/releases/atc/tags"
  echo 'v1.0.1' > "$tree/releases/imp/tags"
  echo 'v0.7.0' > "$tree/releases/nixie/tags"
  echo 'auto-mode-v0.19.3' > "$tree/releases/auto-mode/tags"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","release","list","-R","zgeoff/atc","--exclude-drafts","--exclude-pre-releases","--limit","30","--json","tagName","--jq",".[].tagName"]
["gh","release","list","-R","zgeoff/imp","--exclude-drafts","--exclude-pre-releases","--limit","30","--json","tagName","--jq",".[].tagName"]
["gh","release","list","-R","zgeoff/nixie","--exclude-drafts","--exclude-pre-releases","--limit","30","--json","tagName","--jq",".[].tagName"]
["gh","release","list","-R","zgeoff/auto-mode","--exclude-drafts","--exclude-pre-releases","--limit","30","--json","tagName","--jq",".[].tagName"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_the_atc_line_with_every_pinned_version_when_one_pin_is_older() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.3.0
ARG AUTO_MODE_VERSION=0.19.3
EOF
  echo '  version = "2.26.2";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/deploy/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  echo '@zgeoff/atc@4.3.0' > "$tree/releases/atc/tags"
  echo 'v1.0.1' > "$tree/releases/imp/tags"
  echo 'v0.7.0' > "$tree/releases/nixie/tags"
  echo 'auto-mode-v0.19.3' > "$tree/releases/auto-mode/tags"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'atc 4.3.0 4.3.0 2.26.2 4.3.0'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_the_imp_and_nixie_lines_when_their_pins_are_older() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:0.33.0@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.3.0
ARG AUTO_MODE_VERSION=0.19.3
EOF
  echo '  version = "4.3.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/deploy/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.6.2@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.6.2@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  echo '@zgeoff/atc@4.3.0' > "$tree/releases/atc/tags"
  echo 'v1.0.1' > "$tree/releases/imp/tags"
  echo 'v0.7.0' > "$tree/releases/nixie/tags"
  echo 'auto-mode-v0.19.3' > "$tree/releases/auto-mode/tags"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
imp 1.0.1 1.0.0 0.33.0
nixie 0.7.0 0.6.2 0.6.2
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_the_auto_mode_line_when_the_agent_images_pin_is_older() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.3.0
ARG AUTO_MODE_VERSION=0.17.0
EOF
  echo '  version = "4.3.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/deploy/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  echo '@zgeoff/atc@4.3.0' > "$tree/releases/atc/tags"
  echo 'v1.0.1' > "$tree/releases/imp/tags"
  echo 'v0.7.0' > "$tree/releases/nixie/tags"
  printf '%s\n' 'v9.0.0' 'auto-mode-v0.19.3' 'auto-mode-v0.19.2' 'auto-mode-v0.17.0' > "$tree/releases/auto-mode/tags"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'auto-mode 0.19.3 0.17.0'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_takes_the_highest_version_among_the_tags_of_the_dependencys_own_form() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.2.0
ARG AUTO_MODE_VERSION=0.19.3
EOF
  echo '  version = "4.2.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.2.0' > "$tree/seed/deploy/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  printf '%s\n' '@zgeoff/atc-client@9.0.0' '@zgeoff/atc@4.9.0' '@zgeoff/atc@4.10.0' '@zgeoff/atc@4.3.0' > "$tree/releases/atc/tags"
  printf '%s\n' 'v1.2.3-rc.1' 'v1.0.1' > "$tree/releases/imp/tags"
  echo 'v0.7.0' > "$tree/releases/nixie/tags"
  echo 'auto-mode-v0.19.3' > "$tree/releases/auto-mode/tags"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'atc 4.10.0 4.2.0 4.2.0 4.2.0'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_nothing_for_a_pin_newer_than_the_newest_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.4.0
ARG AUTO_MODE_VERSION=0.19.3
EOF
  echo '  version = "4.3.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/deploy/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  echo '@zgeoff/atc@4.3.0' > "$tree/releases/atc/tags"
  echo 'v1.0.1' > "$tree/releases/imp/tags"
  echo 'v0.7.0' > "$tree/releases/nixie/tags"
  echo 'auto-mode-v0.19.3' > "$tree/releases/auto-mode/tags"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_on_a_missing_pin_before_it_reads_a_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$tree/seed/images/agent/Dockerfile"
  echo '  version = "4.3.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/deploy/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF

  (cd "$tree/seed" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "images/agent/Dockerfile has 0 lines that match '^ARG ATC_VERSION=([0-9]+\\.[0-9]+\\.[0-9]+)\$', want 1"
  [ ! -e "$tree/calls" ] || {
    echo "gh ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_on_a_doubled_pin() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.3.0
ARG AUTO_MODE_VERSION=0.19.3
EOF
  echo '  version = "4.3.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/deploy/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    image: ghcr.io/zgeoff/nixie:0.6.2@sha256:5555555555555555555555555555555555555555555555555555555555555555
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF

  (cd "$tree/seed" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "infra/Pulumi.prod.yaml has 2 lines that match '^ +image: ghcr\\.io/zgeoff/nixie:([0-9]+\\.[0-9]+\\.[0-9]+)@sha256:[0-9a-f]{64}\$', want 1"
  [ ! -e "$tree/calls" ] || {
    echo "gh ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_when_a_repository_has_no_release_of_its_form() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.3.0
ARG AUTO_MODE_VERSION=0.19.3
EOF
  echo '  version = "4.3.0";' > "$tree/seed/nixos/packages/atc.nix"
  echo 'ATC_RELEASE=@zgeoff/atc@4.3.0' > "$tree/seed/deploy/atc-gateway/versions.env"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:3333333333333333333333333333333333333333333333333333333333333333
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  echo '@zgeoff/atc@4.3.0' > "$tree/releases/atc/tags"
  echo 'v1.2.3-rc.1' > "$tree/releases/imp/tags"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'zgeoff/imp has no release tagged vX.Y.Z'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

run_cases
