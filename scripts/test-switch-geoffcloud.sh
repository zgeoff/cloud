#!/usr/bin/env bash
# Stub test for switch-geoffcloud.sh's gate: a switch never follows a failed build, and the
# switch activates the exact store path the build printed, built from the checked commit. It
# touches no host and runs no Nix: docker and ssh are stubs, and the repo is a temporary
# clone with its own origin.
#
#   bash scripts/test-switch-geoffcloud.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
failures=0

teardown() {
  rm -rf "$work"
}
trap teardown EXIT

built_path="/nix/store/$(printf 'a%.0s' {1..32})-nixos-system-geoffcloud-26.05.test"
mkdir -p "$work/bin"

# docker: the build logs what its /src mount holds, may edit the real checkout meanwhile
# (STUB_MUTATE), then prints STUB_BUILD_OUT or fails with STUB_BUILD_FAIL; a copy logs its
# path, and any nixos-rebuild is logged so a test can refuse it
cat > "$work/bin/docker" << 'EOF'
#!/usr/bin/env bash
src=""
for arg in "$@"; do
  case "$arg" in *":/src:ro") src="${arg%:/src:ro}" ;; esac
done
case "$*" in
  *"build --no-link"*)
    seen="$(cat "$src/nixos/marker")"
    if [[ -e "$src/nixos/untracked.nix" ]]; then seen="$seen+untracked"; fi
    echo "build:$seen" >> "$STUB_LOG"
    if [[ -n "${STUB_MUTATE:-}" ]]; then echo "edited" > "$STUB_REPO/nixos/marker"; fi
    if [[ -n "${STUB_BUILD_FAIL:-}" ]]; then echo "error: build failed" >&2; exit 1; fi
    printf '%s\n' "$STUB_BUILD_OUT"
    ;;
  *"copy --to"*) echo "copy:${*: -1}" >> "$STUB_LOG" ;;
  *"nixos-rebuild"*) echo "rebuild" >> "$STUB_LOG" ;;
  *) echo "docker stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
# ssh: activation logs the path whose switch-to-configuration it runs; the host's current
# system is STUB_CURRENT
cat > "$work/bin/ssh" << 'EOF'
#!/usr/bin/env bash
case "$*" in
  *"switch-to-configuration"*)
    path="$(grep -oE '/nix/store/[^/'"'"' ]+/bin/switch-to-configuration' <<< "$*")"
    echo "activate:${path%/bin/switch-to-configuration}" >> "$STUB_LOG"
    ;;
  *"readlink /run/current-system"*) printf '%s\n' "$STUB_CURRENT" ;;
  *"systemctl --failed"*) ;;
  *) echo "ssh stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
# git: the real git, except that `status` fails when STUB_GIT_STATUS_FAIL is set, and with
# STUB_MOVE_HEAD the guard's last read (rev-parse origin/main) commits a new marker right
# after it answers, so HEAD moves between the check and the build
real_git="$(command -v git)"
cat > "$work/bin/git" << EOF
#!/usr/bin/env bash
if [[ -n "\${STUB_GIT_STATUS_FAIL:-}" && " \$* " == *" status "* ]]; then
  echo "fatal: status failed" >&2
  exit 128
fi
if [[ -n "\${STUB_MOVE_HEAD:-}" && " \$* " == *" rev-parse origin/main "* ]]; then
  "$real_git" "\$@"
  echo "moved" > "\$STUB_REPO/nixos/marker"
  "$real_git" -C "\$STUB_REPO" -c user.name=t -c user.email=t@t commit -qam moved
  exit 0
fi
exec "$real_git" "\$@"
EOF
chmod +x "$work/bin/docker" "$work/bin/ssh" "$work/bin/git"

git init -q --bare -b main "$work/origin.git"
git clone -q "$work/origin.git" "$work/clone" 2> /dev/null
mkdir -p "$work/clone/scripts" "$work/clone/nixos"
cp "$repo/scripts/switch-geoffcloud.sh" "$work/clone/scripts/"
echo "committed" > "$work/clone/nixos/marker"
git -C "$work/clone" -c user.name=t -c user.email=t@t add -A
git -C "$work/clone" -c user.name=t -c user.email=t@t commit -qm init
git -C "$work/clone" push -q origin main

# run_case <name> <expected exit: 0 or fail> <expected calls> [env assignments...]
run_case() {
  local name="$1" expected="$2" calls_expected="$3" status=0
  shift 3
  : > "$work/log"
  (cd "$work/clone" && env PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_REPO="$work/clone" \
    STUB_BUILD_OUT="$built_path" STUB_CURRENT="$built_path" "$@" \
    bash scripts/switch-geoffcloud.sh > "$work/out" 2>&1) || status=$?
  local calls
  calls="$(tr '\n' ' ' < "$work/log" | sed 's/ $//')"
  if { [[ "$expected" == 0 && "$status" -ne 0 ]] || [[ "$expected" == fail && "$status" -eq 0 ]]; } \
    || [[ "$calls" != "$calls_expected" ]]; then
    echo "FAIL $name: exit $status, calls [$calls], want exit $expected and [$calls_expected]"
    sed 's/^/  /' "$work/out"
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

ok_calls="build:committed copy:$built_path activate:$built_path"

run_case "a clean build activates its own store path" 0 "$ok_calls"
run_case "an edit during the build changes neither the build nor the switch" 0 "$ok_calls" \
  STUB_MUTATE=1
git -C "$work/clone" checkout -q -- nixos/marker
run_case "a failed build never switches" fail "build:committed" STUB_BUILD_FAIL=1
run_case "a build without a system path never switches" fail "build:committed" \
  STUB_BUILD_OUT="warning: x"
run_case "a host on another system fails after the switch" fail "$ok_calls" \
  STUB_CURRENT="/nix/store/$(printf 'b%.0s' {1..32})-nixos-system-geoffcloud-old"

echo "{ }" > "$work/clone/nixos/untracked.nix"
run_case "an untracked file in nixos/ never reaches the build" 0 "$ok_calls"
rm "$work/clone/nixos/untracked.nix"

run_case "a failing git status never builds" fail "" STUB_GIT_STATUS_FAIL=1

run_case "a commit made after the check never reaches the build" 0 "$ok_calls" STUB_MOVE_HEAD=1
git -C "$work/clone" reset -q --hard origin/main

git -C "$work/clone" checkout -q -b topic
run_case "a branch other than main never builds" fail ""
git -C "$work/clone" checkout -q main

echo "# local edit" >> "$work/clone/scripts/switch-geoffcloud.sh"
run_case "uncommitted changes never build" fail ""
git -C "$work/clone" checkout -q -- scripts/switch-geoffcloud.sh

if ((failures > 0)); then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
