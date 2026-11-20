#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for the agent image's bun and bunx shim, bin/bun: it runs the Bun version that the nearest
# .bun-version pins, and the image's default Bun when there is none, when the image lacks the pin,
# or when the pin is no version. setup_test lays out a fake /opt/bun in the case tree, as the image
# lays out the real one, with a scripted command for each version's bun and bunx that logs to that
# version's own log, and points the shim at it with AGENT_BUN_ROOT. Each case runs the shim with `sh`
# under `env -i`, so CI runs it with dash, the guest's /bin/sh. check-agent-image.ts runs the real
# binaries through the shim in the image.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  load '../../scripts/src/test-utils/shell/create-stub-scripted-command.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
  script="$BATS_TEST_DIRNAME/bin/bun"
}

teardown() {
  stop_timeout_watchdog
}

# a fake /opt/bun with Bun 1.4.2 and 1.4.3, whose calls log to $tree/<version>.log and answer from
# $tree/<version>-answers, the default linked to 1.4.3, and $tree/bin/bun and bunx linked to the
# shim, as /usr/local/bin/bun and bunx are in the image; the cases run from $tree/repo/sub
setup_test() {
  local version
  for version in 1.4.2 1.4.3; do
    mkdir -p "$tree/opt/$version" "$tree/$version-answers"
    create_stub_scripted_command "$tree/opt/$version" bun "$tree/$version.log" "$tree/$version-answers"
    create_stub_scripted_command "$tree/opt/$version" bunx "$tree/$version.log" "$tree/$version-answers"
  done
  ln -s "$tree/opt/1.4.3" "$tree/opt/default"
  mkdir -p "$tree/bin" "$tree/repo/sub"
  ln -s "$script" "$tree/bin/bun"
  ln -s "$script" "$tree/bin/bunx"
}

@test "it runs the version that the folder s bun version pins" {
  setup_test
  echo 1.4.2 > "$tree/repo/.bun-version"
  echo 1.4.2 > "$tree/1.4.2-answers/1.out"

  cd "$tree/repo"
  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" --version

  assert_output 1.4.2
  refute_stderr
  diff - "$tree/1.4.2.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"--version\"]}"
  refute [ -e "$tree/1.4.3.log" ]
  refute [ -L "$tree/1.4.3.log" ]
}

@test "it runs the version that the nearest bun version above the folder pins" {
  setup_test
  echo 1.4.3 > "$tree/.bun-version"
  echo 1.4.2 > "$tree/repo/.bun-version"
  echo 0 > "$tree/1.4.2-answers/1.status"

  cd "$tree/repo/sub"
  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" test a.test.ts

  refute_output
  refute_stderr
  diff - "$tree/1.4.2.log" <<< "{\"cwd\":\"$tree/repo/sub\",\"argv\":[\"bun\",\"test\",\"a.test.ts\"]}"
  refute [ -e "$tree/1.4.3.log" ]
  refute [ -L "$tree/1.4.3.log" ]
}

@test "it runs the pinned version s bunx when called as bunx" {
  setup_test
  echo 1.4.2 > "$tree/repo/.bun-version"
  echo 0 > "$tree/1.4.2-answers/1.status"

  cd "$tree/repo"
  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bunx" oxlint --fix

  refute_output
  refute_stderr
  diff - "$tree/1.4.2.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bunx\",\"oxlint\",\"--fix\"]}"
  refute [ -e "$tree/1.4.3.log" ]
  refute [ -L "$tree/1.4.3.log" ]
}

@test "it reads a pin with a leading v and a crlf line end" {
  setup_test
  printf 'v1.4.2\r\n' > "$tree/repo/.bun-version"
  echo 0 > "$tree/1.4.2-answers/1.status"

  cd "$tree/repo"
  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" --version

  refute_stderr
  diff - "$tree/1.4.2.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"--version\"]}"
  refute [ -e "$tree/1.4.3.log" ]
  refute [ -L "$tree/1.4.3.log" ]
}

@test "it runs the default without a bun version" {
  setup_test
  echo 0 > "$tree/1.4.3-answers/1.status"

  cd "$tree/repo"
  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" --version

  refute_stderr
  diff - "$tree/1.4.3.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"--version\"]}"
  refute [ -e "$tree/1.4.2.log" ]
  refute [ -L "$tree/1.4.2.log" ]
}

@test "it runs the default and names both versions for a pin the image lacks" {
  setup_test
  echo 1.4.4 > "$tree/repo/.bun-version"
  echo 0 > "$tree/1.4.3-answers/1.status"

  cd "$tree/repo/sub"
  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" --version

  assert_stderr "bun: $tree/repo/.bun-version pins Bun 1.4.4, which this image lacks; running 1.4.3"
  diff - "$tree/1.4.3.log" <<< "{\"cwd\":\"$tree/repo/sub\",\"argv\":[\"bun\",\"--version\"]}"
  refute [ -e "$tree/1.4.2.log" ]
  refute [ -L "$tree/1.4.2.log" ]
}

@test "it runs the default for a pin that names a folder outside the root" {
  setup_test
  mkdir -p "$tree/outside" "$tree/outside-answers"
  create_stub_scripted_command "$tree/outside" bun "$tree/outside.log" "$tree/outside-answers"
  echo ../outside > "$tree/repo/.bun-version"
  echo 0 > "$tree/1.4.3-answers/1.status"

  cd "$tree/repo"
  run -0 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" --version

  assert_stderr "bun: $tree/repo/.bun-version pins '../outside', which is no version; running the image's default Bun"
  diff - "$tree/1.4.3.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"--version\"]}"
  refute [ -e "$tree/outside.log" ]
  refute [ -L "$tree/outside.log" ]
}

@test "it passes on the exit status and output of the bun it runs" {
  setup_test
  echo 1.4.2 > "$tree/repo/.bun-version"
  echo '1 fail' > "$tree/1.4.2-answers/1.err"
  echo 1 > "$tree/1.4.2-answers/1.status"

  cd "$tree/repo"
  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" test

  refute_output
  assert_stderr '1 fail'
}
