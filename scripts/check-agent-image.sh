#!/usr/bin/env bash
# Check the agent image (images/agent) from inside a running copy of it: each pinned tool
# answers with the version the Dockerfile pins, no login state or credential file exists,
# and gitleaks finds no secret on the filesystem. Run it from this machine:
#
#   bash scripts/check-agent-image.sh --imp <name>        # a fresh imp from the image
#   bash scripts/check-agent-image.sh --docker <image>    # a local docker build, as CI does
#
# It prints one line per check and exits non-zero when any check fails. It prints names
# only, never a value: gitleaks runs with --redact, and the environment check lists
# variable names. The script changes nothing in the image beyond the gitleaks binary it
# copies to /run/agent-image-check, which is a tmpfs in an imp and a read-only mount in docker.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
dockerfile="$repo/images/agent/Dockerfile"

mode="${1:-}"
target="${2:-}"
if [[ ! "$mode" =~ ^--(imp|docker)$ || -z "$target" ]]; then
  echo "usage: check-agent-image.sh --imp <name> | --docker <image>" >&2
  exit 2
fi

# gitleaks, the release CI's gitleaks job pins, checked against its checksums file
gitleaks_version=8.30.1
gitleaks_sha256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb

work="$(mktemp -d)"
teardown() {
  rm -rf "$work"
}
trap teardown EXIT

mkdir "$work/agent-image-check"
curl -fsSL -o "$work/gitleaks.tar.gz" \
  "https://github.com/gitleaks/gitleaks/releases/download/v${gitleaks_version}/gitleaks_${gitleaks_version}_linux_x64.tar.gz"
echo "$gitleaks_sha256  $work/gitleaks.tar.gz" | sha256sum -c --quiet -
tar -xzf "$work/gitleaks.tar.gz" -C "$work/agent-image-check" gitleaks
cp "$repo/scripts/agent-image-gitleaks.toml" "$work/agent-image-check/gitleaks.toml"

# the guest script, led by the pins and the check's mode: every `ARG NAME=value` line of the
# Dockerfile but the snapshot stamp and the sums, as shell assignments, then check_mode, imp or docker
{
  grep -E '^ARG [A-Z0-9_]+_VERSION=' "$dockerfile" | sed -E "s/^ARG ([A-Z0-9_]+)=(.*)$/\1='\2'/"
  echo "check_mode='${mode#--}'"
  cat << 'GUEST'
set -uo pipefail
failures=0

pass() { printf 'ok    %-16s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-16s %s\n' "$1" "$2"; failures=$((failures + 1)); }

# a tool answers its version command, and the answer holds the pinned version
check_tool() {
  local name="$1" expected="$2"
  shift 2
  local out
  if ! out=$("$@" 2>&1 | head -1); then
    fail "$name" "\`$*\` failed: $out"
  elif [[ "$out" != *"$expected"* ]]; then
    fail "$name" "\`$*\` gave '$out', want $expected"
  else
    pass "$name" "$out"
  fi
}

# an Ubuntu package is installed at the pinned version
check_package() {
  local package="$1" expected="$2" actual
  actual=$(dpkg-query -W -f '${Version}' "$package" 2>/dev/null || true)
  if [[ "$actual" == "$expected" ]]; then
    pass "$package" "deb $actual"
  else
    fail "$package" "deb '${actual:-missing}', want $expected"
  fi
}

# login state and secrets first: a tool can write state when it runs, as `codex --version`
# creates ~/.codex, so the sweep runs last
echo "== login state"
# the files a tool writes when it signs in or stores a credential
login_paths=(
  .claude .claude.json .codex .config/gh .config/op .op .config/auto-mode
  .npmrc .netrc .git-credentials .docker/config.json .pypirc .config/uv/uv.toml
  .bun/install/global .ssh/id_rsa .ssh/id_ecdsa .ssh/id_ed25519
)
homes=(/root /home/*)
found=0
for home in "${homes[@]}"; do
  [[ -d "$home" ]] || continue
  for path in "${login_paths[@]}"; do
    if [[ -e "$home/$path" ]]; then
      fail login-state "$home/$path exists"
      found=1
    fi
  done
done
[[ "$found" == 1 ]] || pass login-state "none of ${#login_paths[@]} paths under ${homes[*]}"
names=$(env | cut -d= -f1 | grep -E 'TOKEN|SECRET|PASSWORD|API_KEY|AUTH|CREDENTIAL' || true)
if [[ -n "$names" ]]; then
  fail environment "credential-like variables: $(echo $names)"
else
  pass environment "no credential-like variable names"
fi

echo "== gitleaks"
# every top-level folder but the kernel's and the runtime's: /proc, /sys, /dev and /run
# hold no image content, and /run holds this check
# the report lists each finding's rule and place; --redact keeps the matched text out of it
report=/run/agent-image-gitleaks.json
for dir in /*/; do
  dir=${dir%/}
  case "$dir" in /proc | /sys | /dev | /run) continue ;; esac
  [[ -L "$dir" ]] && continue
  if out=$(/run/agent-image-check/gitleaks dir "$dir" --config /run/agent-image-check/gitleaks.toml \
    --no-banner --redact --max-target-megabytes 50 --log-level error \
    --report-format json --report-path "$report" 2>&1); then
    pass "gitleaks $dir" "no leaks"
  elif [[ -s "$report" ]] && jq -e 'length > 0' "$report" > /dev/null 2>&1; then
    fail "gitleaks $dir" "$(jq -r '"\(length) leaks: " + ([.[] | "\(.RuleID) \(.File):\(.StartLine)"] | join(", "))' "$report")"
  else
    fail "gitleaks $dir" "gitleaks failed: $out"
  fi
  rm -f "$report"
done

echo "== versions"
check_tool claude "$CLAUDE_CODE_VERSION" claude --version
check_tool atc "$ATC_VERSION" /usr/local/bin/atc --version
check_tool codex "$CODEX_VERSION" codex --version
check_tool gh "$GH_VERSION" gh --version
check_package git "$GIT_VERSION"
git_upstream=${GIT_VERSION#*:}
check_tool git "${git_upstream%%-*}" git --version
check_package jq "$JQ_VERSION"
# Ubuntu's jq 1.7.1 calls itself jq-1.7, so the deb pin above is the version check
check_tool jq "jq-" jq --version
check_package bash "$BASH_VERSION"
check_tool bash "${BASH_VERSION%%-*}" bash --version
check_tool node "v$NODE_VERSION" node --version
check_tool npm "" npm --version
check_tool bun "$BUN_VERSION" bun --version
check_package build-essential "$BUILD_ESSENTIAL_VERSION"
check_tool gcc "" gcc --version
check_tool make "" make --version
check_tool go "go$GO_VERSION" go version
check_package python3 "$PYTHON3_VERSION"
check_tool python3 "${PYTHON3_VERSION%%-*}" python3 --version
check_tool uv "$UV_VERSION" uv --version
check_tool uvx "$UV_VERSION" uvx --version
check_tool op "$OP_VERSION" op --version
check_package docker-compose-plugin "$DOCKER_COMPOSE_VERSION"
check_tool auto-mode "$AUTO_MODE_VERSION" jq -r .version /opt/auto-mode/package.json
check_tool gitleaks "$GITLEAKS_VERSION" gitleaks version
if auto-mode --help > /dev/null 2>&1; then
  pass auto-mode "auto-mode --help exits 0"
else
  fail auto-mode "auto-mode --help failed"
fi
if [[ -f /opt/auto-mode/mods/auto-mode/.claude-plugin/plugin.json ]]; then
  pass auto-mode-mod "/opt/auto-mode/mods/auto-mode"
else
  fail auto-mode-mod "/opt/auto-mode/mods/auto-mode/.claude-plugin/plugin.json is missing"
fi
# the boot service that lets oxc's allocator reserve its buffers on a small imp
overcommit=/etc/imp/services.d/overcommit.json
if [[ "$(jq -c '[.argv, .user, .restart]' "$overcommit" 2> /dev/null)" == '[["sysctl","-w","vm.overcommit_memory=1"],"root","never"]' ]] \
  && command -v sysctl > /dev/null; then
  pass overcommit "$overcommit"
else
  fail overcommit "$overcommit is missing or does not run sysctl -w vm.overcommit_memory=1 once as root"
fi
# the boot service that turns on the swapfile, so a heavy command slows a small imp down
swap=/etc/imp/services.d/swap.json
if [[ "$(jq -c '[.argv, .user, .restart]' "$swap" 2> /dev/null)" == '[["/usr/local/sbin/setup-swap"],"root","never"]' ]] \
  && [[ -x /usr/local/sbin/setup-swap ]] \
  && [[ -x /usr/bin/fallocate && -x /usr/sbin/mkswap && -x /usr/sbin/swapon && -x /usr/sbin/sysctl ]] \
  && command -v df > /dev/null && command -v awk > /dev/null; then
  pass swap "$swap"
else
  fail swap "$swap is missing or does not run /usr/local/sbin/setup-swap once as root, or a tool it runs is missing"
fi
# the swapfile size the service picks, in MiB, for the free space on / that `imp logs <name> swap`
# printed at the first boot of a fresh imp from this image: 1434 MiB on a 4096 MiB test disk, which
# gets no swapfile, and 28215 MiB on a 32 GiB agent disk, which gets the full 2048 MiB
check_swap_size() {
  local name="$1" free_kib="$2" expected="$3" out
  if ! out=$(/usr/local/sbin/setup-swap --size-for "$free_kib" 2>&1); then
    fail "$name" "setup-swap --size-for $free_kib failed: $out"
  elif [[ "$out" != "$expected" ]]; then
    fail "$name" "setup-swap --size-for $free_kib gave '$out' MiB, want $expected"
  else
    pass "$name" "$out MiB for $((free_kib / 1024)) MiB free"
  fi
}
check_swap_size swap-4g $((1434 * 1024)) 0
check_swap_size swap-32g $((28215 * 1024)) 2048
# in an imp, the swapfile the service made at this boot: none when the free space it found was too
# little, or an active one of the size it picks for that free space, which is what is free now plus
# the swapfile itself. Docker has no boot service, and swapon there reads the host's swap.
if [[ "$check_mode" == imp ]]; then
  free_kib=$(df -Pk / | awk 'NR == 2 { print $4 }')
  active=$(/usr/sbin/swapon --show=NAME --noheadings)
  if [[ ! -e /swapfile ]]; then
    want=$(/usr/local/sbin/setup-swap --size-for "$free_kib")
    if [[ -z "$active" && "$want" == 0 ]]; then
      pass swap-live "no swapfile, $((free_kib / 1024)) MiB free"
    else
      fail swap-live "no /swapfile, but swap is '$active' and $((free_kib / 1024)) MiB free would get $want MiB"
    fi
  else
    size_mib=$(($(stat -c %s /swapfile) / 1048576))
    want=$(/usr/local/sbin/setup-swap --size-for "$((free_kib + size_mib * 1024))")
    # what the guest wrote to / since the boot, such as the broker CA, can move want by a few MiB
    if [[ "$active" == /swapfile ]] && ((size_mib >= want - 8 && size_mib <= want + 8)); then
      pass swap-live "$size_mib MiB /swapfile on, $((free_kib / 1024)) MiB free"
    else
      fail swap-live "/swapfile is $size_mib MiB with swap '$active' and $((free_kib / 1024)) MiB free, want $want MiB on"
    fi
  fi
fi
if [[ "${DISABLE_UPDATES:-}" == 1 ]]; then
  pass DISABLE_UPDATES "1"
else
  fail DISABLE_UPDATES "'${DISABLE_UPDATES:-}', want 1"
fi

echo "== $failures failed"
exit $((failures > 0))
GUEST
} > "$work/guest.sh"

case "$mode" in
  --imp)
    imp cp "$work/agent-image-check" "$target:/run/agent-image-check" > /dev/null
    imp exec "$target" -- bash -s < "$work/guest.sh"
    ;;
  --docker)
    docker run --rm -i -v "$work/agent-image-check:/run/agent-image-check:ro" "$target" \
      bash -s < "$work/guest.sh"
    ;;
esac
