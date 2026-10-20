# shellcheck shell=bash
# The guest half of check-agent-image.ts, which runs it as `bash -s` inside a running copy of the
# agent image: in an imp through the imp CLI's `exec`, or in `docker run`. check-agent-image.ts sends it
# after a prelude that assigns every `ARG <NAME>_VERSION=` pin of images/agent/Dockerfile and
# check_mode (imp or docker), and copies the gitleaks binary and its config to
# /run/agent-image-check first. It prints one line per check, names only and never a value, and
# exits 1 when any check fails.
# shellcheck disable=SC2154 # the prelude assigns the pins
set -uo pipefail
failures=0

pass() { printf 'ok    %-16s %s\n' "$1" "$2"; }
fail() {
  printf 'FAIL  %-16s %s\n' "$1" "$2"
  failures=$((failures + 1))
}

# a tool answers its version command, and the answer holds the pinned version.
# The whole output is read before its first line is taken: piping into head -1
# under pipefail fails the check when the tool writes into the closing pipe.
check_tool() {
  local name="$1" expected="$2"
  shift 2
  local out
  if ! out=$("$@" 2>&1); then
    fail "$name" "\`$*\` failed: $out"
  else
    local first=${out%%$'\n'*}
    if [[ "$first" != *"$expected"* ]]; then
      fail "$name" "\`$*\` gave '$first', want $expected"
    else
      pass "$name" "$first"
    fi
  fi
}

# an Ubuntu package is installed at the pinned version
check_package() {
  local package="$1" expected="$2" actual
  actual=$(dpkg-query -W -f '${Version}' "$package" 2> /dev/null || true)
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
  fail environment "credential-like variables: ${names//$'\n'/ }"
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
# bun is a shim that runs the Bun of the nearest .bun-version, and the default, BUN_VERSION, without
# one. The check runs it from a folder with no .bun-version above it, then from one that pins each
# version the image holds.
bun_dir=$(mktemp -d /run/agent-image-bun.XXXXXX)
check_tool bun "$BUN_VERSION" env -C "$bun_dir" bun --version
for pinned in "$BUN_VERSION" "$BUN_OLDER_VERSION"; do
  echo "$pinned" > "$bun_dir/.bun-version"
  check_tool "bun $pinned" "$pinned" env -C "$bun_dir" bun --version
  check_tool "bunx $pinned" "$pinned" env -C "$bun_dir" bunx --version
done
rm -rf "$bun_dir"
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
# the first line that shellcheck prints is its name, so the check reads its version line
check_tool shellcheck "version: $SHELLCHECK_VERSION" \
  bash -o pipefail -c "shellcheck --version | sed -n '/^version: /p'"
check_tool shfmt "v$SHFMT_VERSION" shfmt --version
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
if [[ "$(jq -c '[.argv, .user, .restart]' "$overcommit" 2> /dev/null)" == '[["sysctl","-w","vm.overcommit_memory=1"],"root","never"]' ]] &&
  command -v sysctl > /dev/null; then
  pass overcommit "$overcommit"
else
  fail overcommit "$overcommit is missing or does not run sysctl -w vm.overcommit_memory=1 once as root"
fi
# the boot service that turns on the swapfile, so a heavy command slows a small imp down
swap=/etc/imp/services.d/swap.json
if [[ "$(jq -c '[.argv, .user, .restart]' "$swap" 2> /dev/null)" == '[["/usr/local/sbin/setup-swap"],"root","never"]' ]] &&
  [[ -x /usr/local/sbin/setup-swap ]] &&
  [[ -x /usr/bin/fallocate && -x /usr/sbin/mkswap && -x /usr/sbin/swapon && -x /usr/sbin/sysctl ]] &&
  command -v df > /dev/null && command -v awk > /dev/null; then
  pass swap "$swap"
else
  fail swap "$swap is missing or does not run /usr/local/sbin/setup-swap once as root, or a tool it runs is missing"
fi
# the swapfile size the service picks, in MiB, for the free space on / that the imp CLI's `logs <name> swap`
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
# in an imp, the swapfile the service made at the first boot, against the free space it read then,
# which its first line in the imp agent's log for the service holds: none when it picks none, or an
# active /swapfile of the size it picks. Docker has no boot service, and swapon there reads the
# host's swap.
if [[ "$check_mode" == imp ]]; then
  boot_free_mib=$(sed -n 's|^setup-swap: \([0-9][0-9]*\) MiB free on /.*|\1|p' /var/log/imp/swap.log 2> /dev/null | head -1)
  active=$(/usr/sbin/swapon --show=NAME --noheadings)
  if [[ -z "$boot_free_mib" ]]; then
    fail swap-live "/var/log/imp/swap.log has no 'setup-swap: <n> MiB free on /' line"
  else
    want=$(/usr/local/sbin/setup-swap --size-for "$((boot_free_mib * 1024))")
    if [[ "$want" == 0 && ! -e /swapfile && -z "$active" ]]; then
      pass swap-live "no swapfile for $boot_free_mib MiB free at the first boot"
    elif [[ "$want" != 0 && -f /swapfile && "$active" == /swapfile && "$(stat -c %s /swapfile)" == "$((want * 1048576))" ]]; then
      pass swap-live "$want MiB /swapfile on for $boot_free_mib MiB free at the first boot"
    else
      fail swap-live "$boot_free_mib MiB free at the first boot wants $want MiB, but /swapfile is $(stat -c %s /swapfile 2> /dev/null || echo missing) bytes and swap is '$active'"
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
