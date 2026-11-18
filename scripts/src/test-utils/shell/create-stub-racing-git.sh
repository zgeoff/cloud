# shellcheck shell=bash
# create_stub_racing_git <bin> <real git> <clone> <log>: writes <bin>/git, a stand-in for
# git that lands a commit in <clone> at the one moment no real state reaches: right after
# a `rev-parse origin/main` call. That call runs on the real git and returns its answer;
# when it fails, the stand-in exits with its status and lands nothing; else it writes "moved" to <clone>/nixos/marker, commits it as "moved" and
# appends ["git-moved-head"] to <log>. Every other call goes to the real git unchanged.
create_stub_racing_git() {
  local bin="$1" real_git="$2" clone="$3" log="$4"
  cat > "$bin/git" << STUB
#!/usr/bin/env bash
if [[ " \$* " == *" rev-parse origin/main "* ]]; then
  "$real_git" "\$@" || exit
  echo moved > "$clone/nixos/marker"
  "$real_git" -C "$clone" -c user.name=test -c user.email=test@example.invalid commit -qam moved
  echo '["git-moved-head"]' >> "$log"
  exit 0
fi
exec "$real_git" "\$@"
STUB
  chmod +x "$bin/git"
}
