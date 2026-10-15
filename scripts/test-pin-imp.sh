#!/usr/bin/env bash
# Test for pin-imp.sh: in a case tree that holds nixos/flake.nix, nixos/flake.lock, the host's
# configuration.nix and the agent image's Dockerfile, it moves the imp input to the release
# commit's first 8 hex digits, locks it with `nix flake lock` in the Nix image that scripts/nix-image.sh pins, and
# pins imp-host and imp-base to the release's tag and digests, and nothing else. The lock gets
# NIX_GITHUB_TOKEN as a github.com access token after the caller's NIX_CONFIG, never in an argv
# or the output, and no NIX_CONFIG at all without the token. It keeps an image
# that already holds the release or a newer one, and runs no lock when imp-host stays. It refuses a
# lock that names another commit, a failed lock, an image pinned at the release with another
# digest (with no file changed and no docker call), and bad arguments. docker is the
# create-stub-release-docker.sh stand-in, which writes the lock the case states; each case runs the
# script under `env -i` from the case tree's repository.
#
#   bash scripts/test-pin-imp.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/../test-support/shell/run-cases.sh"
source "$scripts/../test-support/shell/create-stub-release-docker.sh"
source "$scripts/nix-image.sh"

script="$scripts/pin-imp.sh"

# setup_test <tree>: the repository folder the script runs in, with the folders of the four pin
# files and none of the files, the docker stand-in in <tree>/bin, and the home and temp folders
# the script runs with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/repo/nixos/hosts/geoffcloud" "$tree/repo/images/agent" "$tree/bin" \
    "$tree/home" "$tree/tmp"
  create_stub_release_docker "$tree/bin"
}

it_pins_the_input_the_lock_and_both_images() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  cat > "$tree/repo/nixos/flake.nix" << 'EOF'
    imp = {
      url = "github:zgeoff/imp/4211437b";
      inputs.nixpkgs.follows = "nixpkgs";
    };
EOF
  echo '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}' > "$tree/repo/nixos/flake.lock"
  cat > "$tree/repo/nixos/hosts/geoffcloud/configuration.nix" << 'EOF'
  services.imp = {
    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";
  };
EOF
  cat > "$tree/repo/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:0.33.0@sha256:2222222222222222222222222222222222222222222222222222222222222222
ARG ATC_VERSION=4.2.0
EOF
  echo '{"nodes":{"imp":{"locked":{"rev":"c5bea94080fdde9e21e9720295c1ca727302662e"}}}}' > "$tree/flake.lock"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    sha256:4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/repo/nixos/flake.nix" << 'EOF'
    imp = {
      url = "github:zgeoff/imp/c5bea940";
      inputs.nixpkgs.follows = "nixpkgs";
    };
EOF
  diff "$tree/flake.lock" "$tree/repo/nixos/flake.lock"
  diff - "$tree/repo/nixos/hosts/geoffcloud/configuration.nix" << 'EOF'
  services.imp = {
    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:3333333333333333333333333333333333333333333333333333333333333333";
  };
EOF
  diff - "$tree/repo/images/agent/Dockerfile" << 'EOF'
FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:4444444444444444444444444444444444444444444444444444444444444444
ARG ATC_VERSION=4.2.0
EOF
  # the case tree's path and uid vary between runs, so the expected argv takes them as arguments
  jq -cn --arg mount "$tree/repo/nixos:/src" --arg image "$NIX_IMAGE" \
    --arg command "nix --extra-experimental-features 'nix-command flakes' flake lock && chown $(id -u):$(id -g) flake.lock" \
    '["docker","run","--rm","-v",$mount,"-w","/src",$image,"sh","-c",$command]' > "$tree/want-calls"
  diff "$tree/want-calls" "$tree/calls"
  diff - "$tree/out" << 'EOF'
pinned imp 1.0.1 in nixos/flake.nix and nixos/flake.lock: c5bea94080fdde9e21e9720295c1ca727302662e
pinned imp-host 1.0.1: sha256:3333333333333333333333333333333333333333333333333333333333333333
pinned imp-base 1.0.1: sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_hands_the_github_token_to_the_lock_without_printing_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '      url = "github:zgeoff/imp/4211437b";' > "$tree/repo/nixos/flake.nix"
  echo '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}' > "$tree/repo/nixos/flake.lock"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/repo/nixos/hosts/geoffcloud/configuration.nix"
  echo 'FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$tree/repo/images/agent/Dockerfile"
  echo '{"nodes":{"imp":{"locked":{"rev":"c5bea94080fdde9e21e9720295c1ca727302662e"}}}}' > "$tree/flake.lock"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    NIX_GITHUB_TOKEN=ghs_exampletoken bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    sha256:4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/nix-config" <<< 'access-tokens = github.com=ghs_exampletoken'
  jq -cn --arg mount "$tree/repo/nixos:/src" --arg image "$NIX_IMAGE" \
    --arg command "nix --extra-experimental-features 'nix-command flakes' flake lock && chown $(id -u):$(id -g) flake.lock" \
    '["docker","run","--rm","-v",$mount,"-w","/src","-e","NIX_CONFIG",$image,"sh","-c",$command]' > "$tree/want-calls"
  diff "$tree/want-calls" "$tree/calls"
  diff - "$tree/out" << 'EOF'
pinned imp 1.0.1 in nixos/flake.nix and nixos/flake.lock: c5bea94080fdde9e21e9720295c1ca727302662e
pinned imp-host 1.0.1: sha256:3333333333333333333333333333333333333333333333333333333333333333
pinned imp-base 1.0.1: sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_adds_the_github_token_after_the_callers_nix_config() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '      url = "github:zgeoff/imp/4211437b";' > "$tree/repo/nixos/flake.nix"
  echo '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}' > "$tree/repo/nixos/flake.lock"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/repo/nixos/hosts/geoffcloud/configuration.nix"
  echo 'FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$tree/repo/images/agent/Dockerfile"
  echo '{"nodes":{"imp":{"locked":{"rev":"c5bea94080fdde9e21e9720295c1ca727302662e"}}}}' > "$tree/flake.lock"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    NIX_CONFIG='connect-timeout = 5' NIX_GITHUB_TOKEN=ghs_exampletoken bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    sha256:4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/nix-config" << 'EOF'
connect-timeout = 5
access-tokens = github.com=ghs_exampletoken
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_hands_the_lock_no_nix_config_without_a_github_token() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '      url = "github:zgeoff/imp/4211437b";' > "$tree/repo/nixos/flake.nix"
  echo '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}' > "$tree/repo/nixos/flake.lock"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/repo/nixos/hosts/geoffcloud/configuration.nix"
  echo 'FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$tree/repo/images/agent/Dockerfile"
  echo '{"nodes":{"imp":{"locked":{"rev":"c5bea94080fdde9e21e9720295c1ca727302662e"}}}}' > "$tree/flake.lock"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    NIX_CONFIG='access-tokens = example.invalid=other' bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    sha256:4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  jq -cn --arg mount "$tree/repo/nixos:/src" --arg image "$NIX_IMAGE" \
    --arg command "nix --extra-experimental-features 'nix-command flakes' flake lock && chown $(id -u):$(id -g) flake.lock" \
    '["docker","run","--rm","-v",$mount,"-w","/src",$image,"sh","-c",$command]' > "$tree/want-calls"
  diff "$tree/want-calls" "$tree/calls"
  [ ! -e "$tree/nix-config" ] || {
    echo "passed the caller's NIX_CONFIG without NIX_GITHUB_TOKEN: $(cat "$tree/nix-config")" >&2
    exit 1
  }
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_keeps_a_newer_imp_base_and_pins_the_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '      url = "github:zgeoff/imp/4211437b";' > "$tree/repo/nixos/flake.nix"
  echo '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}' > "$tree/repo/nixos/flake.lock"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/repo/nixos/hosts/geoffcloud/configuration.nix"
  echo 'FROM ghcr.io/zgeoff/imp-base:1.1.0@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$tree/repo/images/agent/Dockerfile"
  cp -p "$tree/repo/images/agent/Dockerfile" "$tree/before"
  echo '{"nodes":{"imp":{"locked":{"rev":"c5bea94080fdde9e21e9720295c1ca727302662e"}}}}' > "$tree/flake.lock"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    sha256:4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/images/agent/Dockerfile"
  diff - "$tree/repo/nixos/flake.nix" <<< '      url = "github:zgeoff/imp/c5bea940";'
  diff "$tree/flake.lock" "$tree/repo/nixos/flake.lock"
  diff - "$tree/repo/nixos/hosts/geoffcloud/configuration.nix" <<< '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:3333333333333333333333333333333333333333333333333333333333333333";'
  diff - "$tree/out" << 'EOF'
imp-base 1.1.0 is pinned, which is newer than 1.0.1
pinned imp 1.0.1 in nixos/flake.nix and nixos/flake.lock: c5bea94080fdde9e21e9720295c1ca727302662e
pinned imp-host 1.0.1: sha256:3333333333333333333333333333333333333333333333333333333333333333
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_runs_no_lock_when_imp_host_already_holds_the_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '      url = "github:zgeoff/imp/c5bea940";' > "$tree/repo/nixos/flake.nix"
  echo '{"nodes":{"imp":{"locked":{"rev":"c5bea94080fdde9e21e9720295c1ca727302662e"}}}}' > "$tree/repo/nixos/flake.lock"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.1@sha256:3333333333333333333333333333333333333333333333333333333333333333";' > "$tree/repo/nixos/hosts/geoffcloud/configuration.nix"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.33.0@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$tree/repo/images/agent/Dockerfile"
  cp -pr "$tree/repo/nixos" "$tree/before"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    sha256:4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/before" "$tree/repo/nixos"
  diff - "$tree/repo/images/agent/Dockerfile" <<< 'FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:4444444444444444444444444444444444444444444444444444444444444444'
  [ ! -e "$tree/calls" ] || {
    echo "docker ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  diff - "$tree/out" << 'EOF'
imp-host 1.0.1 is already pinned
pinned imp-base 1.0.1: sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_refuses_a_lock_that_names_another_commit() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '      url = "github:zgeoff/imp/4211437b";' > "$tree/repo/nixos/flake.nix"
  echo '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}' > "$tree/repo/nixos/flake.lock"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/repo/nixos/hosts/geoffcloud/configuration.nix"
  echo 'FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$tree/repo/images/agent/Dockerfile"
  cp -p "$tree/repo/nixos/hosts/geoffcloud/configuration.nix" "$tree/before"
  echo '{"nodes":{"imp":{"locked":{"rev":"9999999999999999999999999999999999999999"}}}}' > "$tree/flake.lock"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    sha256:4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before" "$tree/repo/nixos/hosts/geoffcloud/configuration.nix"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'nixos/flake.lock locks imp at 9999999999999999999999999999999999999999, want c5bea94080fdde9e21e9720295c1ca727302662e'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_when_the_lock_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '      url = "github:zgeoff/imp/4211437b";' > "$tree/repo/nixos/flake.nix"
  echo '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}' > "$tree/repo/nixos/flake.lock"
  cp -p "$tree/repo/nixos/flake.lock" "$tree/before-lock"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/repo/nixos/hosts/geoffcloud/configuration.nix"
  cp -p "$tree/repo/nixos/hosts/geoffcloud/configuration.nix" "$tree/before-config"
  echo 'FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$tree/repo/images/agent/Dockerfile"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_LOCK_ERROR="error: unable to download 'https://api.github.com/repos/zgeoff/imp/commits/c5bea940'" \
    bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    sha256:4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  cmp "$tree/before-lock" "$tree/repo/nixos/flake.lock"
  cmp "$tree/before-config" "$tree/repo/nixos/hosts/geoffcloud/configuration.nix"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: unable to download 'https://api.github.com/repos/zgeoff/imp/commits/c5bea940'"
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_the_release_pinned_with_another_digest_without_writing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '      url = "github:zgeoff/imp/4211437b";' > "$tree/repo/nixos/flake.nix"
  echo '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}' > "$tree/repo/nixos/flake.lock"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";' > "$tree/repo/nixos/hosts/geoffcloud/configuration.nix"
  echo 'FROM ghcr.io/zgeoff/imp-base:1.0.1@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$tree/repo/images/agent/Dockerfile"
  cp -pr "$tree/repo" "$tree/before"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    sha256:4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  diff -r "$tree/before" "$tree/repo"
  [ ! -e "$tree/calls" ] || {
    echo "docker ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'imp-base 1.0.1 is pinned with sha256:2222222222222222222222222222222222222222222222222222222222222222, but the registry lists sha256:4444444444444444444444444444444444444444444444444444444444444444'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_commit_that_is_not_a_full_hash() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script" 1.0.1 c5bea940 \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    sha256:4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "not a commit: 'c5bea940'"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_refuses_a_digest_without_its_algorithm() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e \
    sha256:3333333333333333333333333333333333333333333333333333333333333333 \
    4444444444444444444444444444444444444444444444444444444444444444) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "not an image digest: '4444444444444444444444444444444444444444444444444444444444444444'"
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_prints_its_usage_without_the_digests() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    bash "$script" 1.0.1 c5bea94080fdde9e21e9720295c1ca727302662e) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: pin-imp.sh <version> <commit> <imp-host digest> <imp-base digest>'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

run_cases
