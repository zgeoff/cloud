#!/usr/bin/env bash
# Test for bump-release.sh: for each dependency it reads what the release publishes through gh,
# docker and the npm registry, pins it with the real pin script on the release-check/<dependency>
# branch of a real bare repository in the case tree, and opens the pull request with the labels
# and body its rules give. gh is the create-stub-release-gh.sh stand-in, docker the
# create-stub-release-docker.sh one and curl the create-stub-release-curl.sh one; git is real,
# under `env -i` with git's global and system config off. The script's work folder lives under the
# case's TMPDIR, and the cases mask its random name as <work>.
#
#   bash scripts/test-bump-release.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/test-lib/run-cases.sh"
source "$scripts/test-lib/create-stub-release-gh.sh"
source "$scripts/test-lib/create-stub-release-docker.sh"
source "$scripts/test-lib/create-stub-release-curl.sh"

script="$scripts/bump-release.sh"
source "$scripts/nix-image.sh"

# setup_test <tree>: a bare repository at <tree>/origin.git, a working repository at <tree>/seed
# whose origin it is, the gh, docker and curl stand-ins in <tree>/bin, and the home and temp
# folders the cases run with. It sets case_env, the environment every git and script call in a
# case runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/seed"
  create_stub_release_gh "$tree/bin"
  create_stub_release_docker "$tree/bin"
  create_stub_release_curl "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp"
    STUB_TREE="$tree" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid)
  "${case_env[@]}" git init -q --bare -b main "$tree/origin.git"
  "${case_env[@]}" git -C "$tree/seed" init -q -b main
  "${case_env[@]}" git -C "$tree/seed" remote add origin "$tree/origin.git"
}

it_opens_an_atc_bump_that_waits_for_review_on_a_major_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/nixos/packages" "$tree/seed/deploy/atc-gateway"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
ARG ATC_VERSION=4.2.0
ARG ATC_SHA256=1111111111111111111111111111111111111111111111111111111111111111
EOF
  cat > "$tree/seed/nixos/packages/atc.nix" << 'EOF'
let
  version = "2.26.2";
  sha256 = "2222222222222222222222222222222222222222222222222222222222222222";
in
EOF
  cat > "$tree/seed/deploy/atc-gateway/versions.env" << 'EOF'
ATC_RELEASE=@zgeoff/atc@2.27.0
ATC_ASSET=atc-gateway-linux-x64
ATC_ASSET_SHA256=3333333333333333333333333333333333333333333333333333333333333333
GATEWAY_IMAGE_TAG=2.27.0
EOF
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  mkdir -p "$tree/releases/atc/@zgeoff_atc@5.0.0"
  cat > "$tree/releases/atc/@zgeoff_atc@5.0.0/SHA256SUMS" << 'EOF'
4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64
5555555555555555555555555555555555555555555555555555555555555555  atc-gateway-linux-x64
EOF

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" atc 5.0.0 4.2.0 2.26.2 2.27.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
pinned atc 5.0.0: 4444444444444444444444444444444444444444444444444444444444444444
pinned atc 5.0.0 in nixos/packages/atc.nix: 4444444444444444444444444444444444444444444444444444444444444444
pinned atc 5.0.0 in deploy/atc-gateway/versions.env: 5555555555555555555555555555555555555555555555555555555555555555
https://github.com/zgeoff/cloud/pull/200
EOF
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" diff --stat=200 main release-check/atc) << 'EOF'
 deploy/atc-gateway/versions.env | 6 +++---
 images/agent/Dockerfile         | 4 ++--
 nixos/packages/atc.nix          | 4 ++--
 3 files changed, 7 insertions(+), 7 deletions(-)
EOF
  diff - "$tree/body" << 'EOF'
Bumps atc to [5.0.0](https://github.com/zgeoff/atc/releases/tag/%40zgeoff/atc%405.0.0). The release check opened this pull request.

| Pin | From | To |
| --- | --- | --- |
| the agent image (`images/agent/Dockerfile`) | 4.2.0 | 5.0.0 |
| the host's atc daemon (`nixos/packages/atc.nix`) | 2.26.2 | 5.0.0 |
| the atc-gateway images (`deploy/atc-gateway/versions.env`) | 2.27.0 | 5.0.0 |

It waits for a review, because:

- it is a major release.

After the merge: Rebuild the agent image (`docs/runbooks/agent-image.md`) and publish the atc-gateway images. The `Deploy prod` workflow applies the pull request that pins their digests once it merges (`docs/runbooks/prod-apply.md`). Then switch the host (`docs/runbooks/workflows.md`), which refuses while the deployed gateway runs another atc major than the daemon pin.
EOF
  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/calls" > "$tree/calls.masked"
  diff - "$tree/calls.masked" << 'EOF'
["gh","release","download","@zgeoff/atc@5.0.0","-R","zgeoff/atc","-p","SHA256SUMS","-D","<work>"]
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:major","--repo","zgeoff/cloud","--force","--color","d73a4a","--description","a major release"]
["gh","label","create","needs-review","--repo","zgeoff/cloud","--force","--color","d73a4a","--description","waits for a review before it merges"]
["gh","pr","create","--repo","zgeoff/cloud","--base","main","--head","release-check/atc","--title","chore(atc): bump atc to 5.0.0","--body-file","<work>/body","--label","update:major,needs-review"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_opens_an_imp_patch_bump_that_merges_on_its_own() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/nixos/hosts/geoffcloud"
  echo 'FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:6666666666666666666666666666666666666666666666666666666666666666' > "$tree/seed/images/agent/Dockerfile"
  cat > "$tree/seed/nixos/flake.nix" << 'EOF'
    imp = {
      url = "github:zgeoff/imp/4211437b";
    };
EOF
  echo '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}' > "$tree/seed/nixos/flake.lock"
  echo '    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:7777777777777777777777777777777777777777777777777777777777777777";' > "$tree/seed/nixos/hosts/geoffcloud/configuration.nix"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  mkdir -p "$tree/releases/imp/v1.0.1" "$tree/images"
  echo c5bea94080fdde9e21e9720295c1ca727302662e > "$tree/releases/imp/v1.0.1/commit"
  echo '{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","digest":"sha256:8888888888888888888888888888888888888888888888888888888888888888","size":1}' > "$tree/images/ghcr.io_zgeoff_imp-host:1.0.1.json"
  echo '{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","digest":"sha256:9999999999999999999999999999999999999999999999999999999999999999","size":1}' > "$tree/images/ghcr.io_zgeoff_imp-base:1.0.1.json"
  echo '{"nodes":{"imp":{"locked":{"rev":"c5bea94080fdde9e21e9720295c1ca727302662e"}}}}' > "$tree/flake.lock"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" imp 1.0.1 1.0.0 1.0.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
pinned imp 1.0.1 in nixos/flake.nix and nixos/flake.lock: c5bea94080fdde9e21e9720295c1ca727302662e
pinned imp-host 1.0.1: sha256:8888888888888888888888888888888888888888888888888888888888888888
pinned imp-base 1.0.1: sha256:9999999999999999999999999999999999999999999999999999999999999999
https://github.com/zgeoff/cloud/pull/200
EOF
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" show release-check/imp:nixos/flake.nix) << 'EOF'
    imp = {
      url = "github:zgeoff/imp/c5bea940";
    };
EOF
  diff - "$tree/body" << 'EOF'
Bumps imp to [1.0.1](https://github.com/zgeoff/imp/releases/tag/v1.0.1). The release check opened this pull request.

| Pin | From | To |
| --- | --- | --- |
| imp's NixOS module and the imp-host image (`nixos/`) | 1.0.0 | 1.0.1 |
| the imp-base image (`images/agent/Dockerfile`) | 1.0.0 | 1.0.1 |

It merges on its own once every check on its head passes, including the NixOS checks when it changes `nixos/`.

After the merge: Copy impd's database, then switch the host, as `docs/runbooks/workflows.md` (Upgrade imp) describes; rebuild the agent image for imp-base (`docs/runbooks/agent-image.md`).
EOF
  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g; s|$tree/clone|<clone>|g" "$tree/calls" > "$tree/calls.masked"
  diff - "$tree/calls.masked" << EOF
["gh","api","repos/zgeoff/imp/commits/v1.0.1","--jq",".sha"]
["docker","buildx","imagetools","inspect","ghcr.io/zgeoff/imp-host:1.0.1","--format","{{json .Manifest}}"]
["docker","buildx","imagetools","inspect","ghcr.io/zgeoff/imp-base:1.0.1","--format","{{json .Manifest}}"]
["docker","run","--rm","-v","<clone>/nixos:/src","-w","/src","$NIX_IMAGE","sh","-c","nix --extra-experimental-features 'nix-command flakes' flake lock && chown $(id -u):$(id -g) flake.lock"]
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","create","--repo","zgeoff/cloud","--base","main","--head","release-check/imp","--title","chore(imp): bump imp to 1.0.1","--body-file","<work>/body","--label","update:patch,auto-merge"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_flags_a_nixie_bump_with_the_migrations_of_a_release_between() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/infra"
  cat > "$tree/seed/infra/Pulumi.prod.yaml" << 'EOF'
  geoff-cloud:nixie:
    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  mkdir -p "$tree/releases/nixie/v0.7.0" "$tree/releases/nixie/v0.7.1" "$tree/releases/nixie/v0.7.2"
  printf 'v0.7.2\nv0.7.1\nv0.7.0\nv0.6.2\n' > "$tree/releases/nixie/tags"
  cat > "$tree/releases/nixie/v0.7.0/notes.md" << 'EOF'
## Migrations

This release adds no migration since v0.6.2.

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc`
- `ghcr.io/zgeoff/nixie@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
- `ghcr.io/zgeoff/nixie-web@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`
EOF
  cat > "$tree/releases/nixie/v0.7.1/notes.md" << 'EOF'
## Migrations

The migrations this release adds since v0.7.0, and whether v0.7.0 can read the schema each leaves.

| Version | Migration | Readable by v0.7.0 |
| ------- | --------- | ------------------ |
| 10 | create the reminders table | yes |
EOF
  cat > "$tree/releases/nixie/v0.7.2/notes.md" << 'EOF'
## Migrations

This release adds no migration since v0.7.1.

## Images

- `ghcr.io/zgeoff/nixie-fetch@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc`
- `ghcr.io/zgeoff/nixie@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd`
- `ghcr.io/zgeoff/nixie-web@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee`
EOF

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" nixie 0.7.2 0.7.0 0.7.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
pinned nixie 0.7.2: sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
pinned nixie-web 0.7.2: sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
https://github.com/zgeoff/cloud/pull/200
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/body" << 'EOF'
Bumps nixie to [0.7.2](https://github.com/zgeoff/nixie/releases/tag/v0.7.2). The release check opened this pull request.

| Pin | From | To |
| --- | --- | --- |
| nixie (`infra/Pulumi.prod.yaml`) | 0.7.0 | 0.7.2 |
| nixie-web (`infra/Pulumi.prod.yaml`) | 0.7.0 | 0.7.2 |

It waits for a review, because:

- a release in the bump adds database migrations, which a revert does not undo.

After the merge: The `Deploy prod` workflow applies the stack config once CI passes on main, unless its guard holds the plan (`docs/runbooks/prod-apply.md`). Check the deploy (`docs/runbooks/nixie.md`).
EOF
  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/calls" > "$tree/calls.masked"
  diff - "$tree/calls.masked" << 'EOF'
["gh","release","view","v0.7.0","-R","zgeoff/nixie","--json","body","--jq",".body"]
["gh","release","view","v0.7.2","-R","zgeoff/nixie","--json","body","--jq",".body"]
["gh","release","list","-R","zgeoff/nixie","--exclude-drafts","--exclude-pre-releases","--limit","30","--json","tagName","--jq",".[].tagName"]
["gh","release","view","v0.7.1","-R","zgeoff/nixie","--json","body","--jq",".body"]
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/nixie","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","migrations","--repo","zgeoff/cloud","--force","--color","d73a4a","--description","the release adds database migrations"]
["gh","label","create","needs-review","--repo","zgeoff/cloud","--force","--color","d73a4a","--description","waits for a review before it merges"]
["gh","pr","create","--repo","zgeoff/cloud","--base","main","--head","release-check/nixie","--title","chore(nixie): bump nixie to 0.7.2","--body-file","<work>/body","--label","update:patch,migrations,needs-review"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_opens_an_auto_mode_patch_bump_that_merges_on_its_own() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent"
  cat > "$tree/seed/images/agent/Dockerfile" << 'EOF'
ARG AUTO_MODE_VERSION=0.19.3
ARG AUTO_MODE_SHA256=de2116ce480885d0a25c277ef897b3e78032065507e3625ef45a5b3248f716d8
EOF
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  mkdir -p "$tree/pack/package" "$tree/npm/auto-mode"
  echo '{"name":"auto-mode","version":"0.19.4"}' > "$tree/pack/package/package.json"
  tar -czf "$tree/npm/auto-mode/auto-mode-0.19.4.tgz" -C "$tree/pack" package
  integrity="sha512-$(openssl dgst -sha512 -binary "$tree/npm/auto-mode/auto-mode-0.19.4.tgz" | base64 -w0)"
  sum="$(sha256sum "$tree/npm/auto-mode/auto-mode-0.19.4.tgz" | cut -d' ' -f1)"
  printf '{"name":"auto-mode","version":"0.19.4","dist":{"tarball":"https://registry.npmjs.org/auto-mode/-/auto-mode-0.19.4.tgz","integrity":"%s"}}\n' "$integrity" > "$tree/npm/auto-mode/0.19.4.json"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" auto-mode 0.19.4 0.19.3) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << EOF
pinned auto-mode 0.19.4: $sum
https://github.com/zgeoff/cloud/pull/200
EOF
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" show release-check/auto-mode:images/agent/Dockerfile) << EOF
ARG AUTO_MODE_VERSION=0.19.4
ARG AUTO_MODE_SHA256=$sum
EOF
  diff - "$tree/body" << 'EOF'
Bumps auto-mode to [0.19.4](https://github.com/zgeoff/auto-mode/releases/tag/auto-mode-v0.19.4). The release check opened this pull request.

| Pin | From | To |
| --- | --- | --- |
| the agent image (`images/agent/Dockerfile`) | 0.19.3 | 0.19.4 |

It merges on its own once every check on its head passes, including the NixOS checks when it changes `nixos/`.

After the merge: Rebuild the agent image (`docs/runbooks/agent-image.md`). Gateway sessions load the new mod from `/opt/auto-mode/mods/auto-mode` once they start on the new image.
EOF
  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/calls" > "$tree/calls.masked"
  diff - "$tree/calls.masked" << 'EOF'
["curl","-fsSL","https://registry.npmjs.org/auto-mode/0.19.4"]
["curl","-fsSL","-o","<work>/auto-mode.tgz","https://registry.npmjs.org/auto-mode/-/auto-mode-0.19.4.tgz"]
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/auto-mode","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","create","--repo","zgeoff/cloud","--base","main","--head","release-check/auto-mode","--title","chore(auto-mode): bump auto-mode to 0.19.4","--body-file","<work>/body","--label","update:patch,auto-merge"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_without_a_pull_request_when_npm_lacks_the_auto_mode_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" auto-mode 0.19.4 0.19.3) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'curl: (22) The requested URL returned error: 404'
  diff - "$tree/calls" <<< '["curl","-fsSL","https://registry.npmjs.org/auto-mode/0.19.4"]'
  [ "$status" = 22 ] || {
    echo "exit $status, want 22" >&2
    exit 1
  }
}

it_refuses_an_auto_mode_tarball_away_from_where_the_image_fetches_it() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/npm/auto-mode"
  echo '{"name":"auto-mode","version":"0.19.4","dist":{"tarball":"https://registry.example.invalid/auto-mode-0.19.4.tgz","integrity":"sha512-x"}}' > "$tree/npm/auto-mode/0.19.4.json"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" auto-mode 0.19.4 0.19.3) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "npm lists auto-mode 0.19.4's tarball at https://registry.example.invalid/auto-mode-0.19.4.tgz, not where the agent image fetches it"
  diff - "$tree/calls" <<< '["curl","-fsSL","https://registry.npmjs.org/auto-mode/0.19.4"]'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_without_a_pull_request_when_the_release_lacks_its_sums() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" atc 5.0.0 4.2.0 2.26.2 2.27.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'release not found'
  sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/calls" > "$tree/calls.masked"
  diff - "$tree/calls.masked" <<< '["gh","release","download","@zgeoff/atc@5.0.0","-R","zgeoff/atc","-p","SHA256SUMS","-D","<work>"]'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_dependency_it_does_not_know() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" atc-gateway 5.0.0 4.2.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "not a release check dependency: 'atc-gateway'"
  [ ! -e "$tree/calls" ] || {
    echo "a stand-in ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_refuses_a_pinned_version_count_that_does_not_match_the_pins() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/releases/atc/@zgeoff_atc@5.0.0"
  echo '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64' > "$tree/releases/atc/@zgeoff_atc@5.0.0/SHA256SUMS"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" atc 5.0.0 4.2.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'atc has 3 pins, but 1 pinned versions were given'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_prints_its_usage_without_a_pinned_version() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" atc 5.0.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: bump-release.sh <dependency> <version> <pinned version>...'
  [ ! -e "$tree/calls" ] || {
    echo "a stand-in ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_fails_without_a_pull_request_when_the_release_list_misses_the_pinned_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/releases/nixie/v0.5.0" "$tree/releases/nixie/v0.7.2"
  printf 'v0.7.2\nv0.7.1\n' > "$tree/releases/nixie/tags"
  printf '## Migrations\n\nThis release adds no migration since v0.4.0.\n' > "$tree/releases/nixie/v0.5.0/notes.md"
  printf '## Migrations\n\nThis release adds no migration since v0.7.1.\n' > "$tree/releases/nixie/v0.7.2/notes.md"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" nixie 0.7.2 0.5.0 0.5.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the latest 30 nixie releases do not reach the pinned v0.5.0, so the releases between go unread'
  diff - "$tree/calls" << 'EOF'
["gh","release","view","v0.5.0","-R","zgeoff/nixie","--json","body","--jq",".body"]
["gh","release","view","v0.7.2","-R","zgeoff/nixie","--json","body","--jq",".body"]
["gh","release","list","-R","zgeoff/nixie","--exclude-drafts","--exclude-pre-releases","--limit","30","--json","tagName","--jq",".[].tagName"]
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

run_cases
