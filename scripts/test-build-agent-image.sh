#!/usr/bin/env bash
# Test for build-agent-image.sh: from a clone of a real bare repository in the case tree, it
# builds agent-<short sha> from a git archive of a commit on origin's main, checks it on a fresh
# imp with that commit's check script, removes the imp, and prints the image and its digest. A
# failed check removes the image, or keeps it with --keep. It refuses a commit off main, an image
# or check imp name that is taken, a failed build and a build that outlives its timeout. imp is
# the create-stub-imp.sh stand-in, and the check is create-stub-check-agent-image.sh committed
# into the case repository; git is real, under `env -i` with git's global and system config off.
#
#   bash scripts/test-build-agent-image.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/test-lib/run-cases.sh"
source "$scripts/test-lib/create-stub-imp.sh"
source "$scripts/test-lib/create-stub-check-agent-image.sh"

script="$scripts/build-agent-image.sh"

# setup_test <tree>: a bare repository at <tree>/origin.git, a working repository at <tree>/seed
# whose origin it is, the imp stand-in in <tree>/bin, and the home and temp folders the cases run
# with. It sets case_env, the environment every git and script call in a case runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/seed"
  create_stub_imp "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp"
    STUB_TREE="$tree" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid)
  "${case_env[@]}" git init -q --bare -b main "$tree/origin.git"
  "${case_env[@]}" git -C "$tree/seed" init -q -b main
  "${case_env[@]}" git -C "$tree/seed" remote add origin "$tree/origin.git"
}

it_builds_and_checks_the_image_from_the_head_of_main() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/scripts"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.33.0' > "$tree/seed/images/agent/Dockerfile"
  create_stub_check_agent_image "$tree/seed/scripts/check-agent-image.sh"
  echo '# gitleaks config' > "$tree/seed/scripts/agent-image-gitleaks.toml"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  sha="$("${case_env[@]}" git -C "$tree/seed" rev-parse HEAD)"
  short="$("${case_env[@]}" git -C "$tree/seed" rev-parse --short HEAD)"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "agent-$short imp-build-stub-agent-$short check passed"
  diff - "$tree/err" << EOF
building agent-$short from $sha; imp image build shows no progress off a terminal
checking agent-$short on a fresh imp, agent-check-$short
agent-check-$short
== 0 failed
EOF
  diff - "$tree/build-saw/Dockerfile" <<< 'FROM ghcr.io/zgeoff/imp-base:0.33.0'
  diff - <(jq -c . "$tree/imp-state.json") <<< "{\"images\":[{\"name\":\"agent-$short\",\"digest\":\"imp-build-stub-agent-$short\"}],\"imps\":[]}"
  diff - <(sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/calls") << EOF
["imp","image","ls","--json"]
["imp","ls","--json"]
["imp","image","build","<work>/src/images/agent","--name","agent-$short"]
["imp","image","ls","--json"]
["imp","new","agent-check-$short","--image","agent-$short"]
["check-agent-image.sh","--imp","agent-check-$short"]
["imp","rm","agent-check-$short"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_builds_an_older_commit_on_main() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/scripts"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.33.0' > "$tree/seed/images/agent/Dockerfile"
  create_stub_check_agent_image "$tree/seed/scripts/check-agent-image.sh"
  echo '# gitleaks config' > "$tree/seed/scripts/agent-image-gitleaks.toml"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  sha="$("${case_env[@]}" git -C "$tree/seed" rev-parse HEAD)"
  short="$("${case_env[@]}" git -C "$tree/seed" rev-parse --short HEAD)"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.34.0' > "$tree/seed/images/agent/Dockerfile"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'bump imp-base'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" "$sha") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "agent-$short imp-build-stub-agent-$short check passed"
  diff - "$tree/build-saw/Dockerfile" <<< 'FROM ghcr.io/zgeoff/imp-base:0.33.0'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_removes_the_image_when_its_check_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/scripts"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.33.0' > "$tree/seed/images/agent/Dockerfile"
  create_stub_check_agent_image "$tree/seed/scripts/check-agent-image.sh"
  echo '# gitleaks config' > "$tree/seed/scripts/agent-image-gitleaks.toml"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  sha="$("${case_env[@]}" git -C "$tree/seed" rev-parse HEAD)"
  short="$("${case_env[@]}" git -C "$tree/seed" rev-parse --short HEAD)"

  (cd "$tree/clone" && "${case_env[@]}" STUB_CHECK_FAILURES=2 bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "agent-$short check failed; removed the image"
  diff - "$tree/err" << EOF
building agent-$short from $sha; imp image build shows no progress off a terminal
checking agent-$short on a fresh imp, agent-check-$short
agent-check-$short
== 2 failed
EOF
  diff - <(jq -c . "$tree/imp-state.json") <<< '{"images":[],"imps":[]}'
  diff - <(sed "s|$tree/tmp/tmp\.[A-Za-z0-9]*|<work>|g" "$tree/calls") << EOF
["imp","image","ls","--json"]
["imp","ls","--json"]
["imp","image","build","<work>/src/images/agent","--name","agent-$short"]
["imp","image","ls","--json"]
["imp","new","agent-check-$short","--image","agent-$short"]
["check-agent-image.sh","--imp","agent-check-$short"]
["imp","rm","agent-check-$short"]
["imp","image","rm","agent-$short"]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_keeps_the_image_when_its_check_fails_with_keep() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/scripts"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.33.0' > "$tree/seed/images/agent/Dockerfile"
  create_stub_check_agent_image "$tree/seed/scripts/check-agent-image.sh"
  echo '# gitleaks config' > "$tree/seed/scripts/agent-image-gitleaks.toml"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  short="$("${case_env[@]}" git -C "$tree/seed" rev-parse --short HEAD)"

  (cd "$tree/clone" && "${case_env[@]}" STUB_CHECK_FAILURES=2 bash "$script" --keep) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "agent-$short imp-build-stub-agent-$short check failed; kept the image"
  diff - <(jq -c . "$tree/imp-state.json") <<< "{\"images\":[{\"name\":\"agent-$short\",\"digest\":\"imp-build-stub-agent-$short\"}],\"imps\":[]}"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_without_an_imp_when_the_build_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/scripts"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.33.0' > "$tree/seed/images/agent/Dockerfile"
  create_stub_check_agent_image "$tree/seed/scripts/check-agent-image.sh"
  echo '# gitleaks config' > "$tree/seed/scripts/agent-image-gitleaks.toml"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  sha="$("${case_env[@]}" git -C "$tree/seed" rev-parse HEAD)"
  short="$("${case_env[@]}" git -C "$tree/seed" rev-parse --short HEAD)"

  (cd "$tree/clone" && "${case_env[@]}" STUB_IMP_BUILD_ERROR='imp: BUILD_FAILED: the build exited 1' bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << EOF
building agent-$short from $sha; imp image build shows no progress off a terminal
imp: BUILD_FAILED: the build exited 1
imp image build failed for agent-$short
EOF
  diff - <(jq -c . "$tree/imp-state.json") <<< '{"images":[],"imps":[]}'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_the_build_outlives_its_timeout() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/scripts"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.33.0' > "$tree/seed/images/agent/Dockerfile"
  create_stub_check_agent_image "$tree/seed/scripts/check-agent-image.sh"
  echo '# gitleaks config' > "$tree/seed/scripts/agent-image-gitleaks.toml"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  sha="$("${case_env[@]}" git -C "$tree/seed" rev-parse HEAD)"
  short="$("${case_env[@]}" git -C "$tree/seed" rev-parse --short HEAD)"

  # the shortest timeout `timeout` takes in whole seconds, against a build that sleeps past it
  (cd "$tree/clone" && "${case_env[@]}" STUB_IMP_BUILD_SECONDS=5 AGENT_IMAGE_BUILD_TIMEOUT=1s bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << EOF
building agent-$short from $sha; imp image build shows no progress off a terminal
imp image build did not finish within 1s; impd may still finish agent-$short, so read imp image ls before a retry
EOF
  diff - <(jq -c . "$tree/imp-state.json") <<< '{"images":[],"imps":[]}'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_commit_that_is_not_on_main() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/scripts"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.33.0' > "$tree/seed/images/agent/Dockerfile"
  create_stub_check_agent_image "$tree/seed/scripts/check-agent-image.sh"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc topic
  echo 'FROM ghcr.io/zgeoff/imp-base:0.34.0' > "$tree/seed/images/agent/Dockerfile"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'bump imp-base'
  "${case_env[@]}" git -C "$tree/seed" push -q origin topic
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  sha="$("${case_env[@]}" git -C "$tree/seed" rev-parse HEAD)"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" origin/topic) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$sha is not on origin/main: build only a commit that main holds"
  [ ! -e "$tree/calls" ] || { echo "imp ran: $(cat "$tree/calls")" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_an_image_name_that_is_taken() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/scripts"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.33.0' > "$tree/seed/images/agent/Dockerfile"
  create_stub_check_agent_image "$tree/seed/scripts/check-agent-image.sh"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  short="$("${case_env[@]}" git -C "$tree/seed" rev-parse --short HEAD)"
  echo "{\"images\":[{\"name\":\"agent-$short\",\"digest\":\"imp-build-1\"}],\"imps\":[]}" > "$tree/imp-state.json"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "image agent-$short already exists: remove it with imp image rm, or build another commit"
  diff - "$tree/calls" <<< '["imp","image","ls","--json"]'
  diff - <(jq -c . "$tree/imp-state.json") <<< "{\"images\":[{\"name\":\"agent-$short\",\"digest\":\"imp-build-1\"}],\"imps\":[]}"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_refuses_a_check_imp_name_that_is_taken() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/seed/images/agent" "$tree/seed/scripts"
  echo 'FROM ghcr.io/zgeoff/imp-base:0.33.0' > "$tree/seed/images/agent/Dockerfile"
  create_stub_check_agent_image "$tree/seed/scripts/check-agent-image.sh"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the image'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  short="$("${case_env[@]}" git -C "$tree/seed" rev-parse --short HEAD)"
  echo "{\"images\":[{\"name\":\"agent-1\",\"digest\":\"imp-build-1\"}],\"imps\":[{\"name\":\"agent-check-$short\",\"image\":\"agent-1\"}]}" > "$tree/imp-state.json"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "imp agent-check-$short already exists: remove it with imp rm first"
  diff - "$tree/calls" << 'EOF'
["imp","image","ls","--json"]
["imp","ls","--json"]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_prints_its_usage_for_an_unknown_option() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" --switch) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: build-agent-image.sh [--keep] [<commit on main>]'
  [ ! -e "$tree/calls" ] || { echo "imp ran: $(cat "$tree/calls")" >&2; exit 1; }
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

run_cases
