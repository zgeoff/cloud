#!/usr/bin/env bash
# Stub test for switch-geoffcloud.sh's gate: a switch never follows a failed build. It
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

# docker: the build prints STUB_BUILD_OUT, or fails with STUB_BUILD_FAIL; the switch is logged
cat > "$work/bin/docker" << 'EOF'
#!/usr/bin/env bash
case "$*" in
  *"build --no-link"*)
    echo "build" >> "$STUB_LOG"
    if [[ -n "${STUB_BUILD_FAIL:-}" ]]; then echo "error: build failed" >&2; exit 1; fi
    printf '%s\n' "$STUB_BUILD_OUT"
    ;;
  *"nixos-rebuild switch"*) echo "switch" >> "$STUB_LOG" ;;
  *) echo "docker stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
# ssh: the host's current system is STUB_CURRENT; systemctl --failed lists nothing
cat > "$work/bin/ssh" << 'EOF'
#!/usr/bin/env bash
case "$*" in
  *"readlink /run/current-system"*) printf '%s\n' "$STUB_CURRENT" ;;
  *"systemctl --failed"*) ;;
  *) echo "ssh stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/docker" "$work/bin/ssh"

git init -q --bare -b main "$work/origin.git"
git clone -q "$work/origin.git" "$work/clone" 2> /dev/null
mkdir -p "$work/clone/scripts"
cp "$repo/scripts/switch-geoffcloud.sh" "$work/clone/scripts/"
git -C "$work/clone" -c user.name=t -c user.email=t@t add -A
git -C "$work/clone" -c user.name=t -c user.email=t@t commit -qm init
git -C "$work/clone" push -q origin main

# run_case <name> <expected exit: 0 or fail> <expected log> [env assignments...]
run_case() {
  local name="$1" expected="$2" log_expected="$3" status=0
  shift 3
  : > "$work/log"
  (cd "$work/clone" && env PATH="$work/bin:$PATH" STUB_LOG="$work/log" \
    STUB_BUILD_OUT="$built_path" STUB_CURRENT="$built_path" "$@" \
    bash scripts/switch-geoffcloud.sh > "$work/out" 2>&1) || status=$?
  local log
  log="$(tr '\n' ' ' < "$work/log" | sed 's/ $//')"
  if { [[ "$expected" == 0 && "$status" -ne 0 ]] || [[ "$expected" == fail && "$status" -eq 0 ]]; } \
    || [[ "$log" != "$log_expected" ]]; then
    echo "FAIL $name: exit $status, calls [$log], want exit $expected and [$log_expected]"
    sed 's/^/  /' "$work/out"
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

run_case "a clean build switches" 0 "build switch"
run_case "a failed build never switches" fail "build" STUB_BUILD_FAIL=1
run_case "a build without a system path never switches" fail "build" STUB_BUILD_OUT="warning: x"
run_case "a host on another system fails after the switch" fail "build switch" \
  STUB_CURRENT="/nix/store/$(printf 'b%.0s' {1..32})-nixos-system-geoffcloud-old"

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
