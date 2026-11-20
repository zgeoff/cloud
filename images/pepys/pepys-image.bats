#!/usr/bin/env bats
# bats file_tags=suite:pepys-image
# Image test for cloud-pepys (images/pepys/Dockerfile), run locally with Docker. It touches no
# cluster and no cloud account.
#
# It runs each of the image's three programs as the pods run them: as the image's user, on a
# read-only root, with no capabilities and no privilege escalation. What this proves: each program
# is executable and starts as nonroot, and that user can read consumers.json and every module,
# while root owns them and only root could write the top folder. What it does not prove: the real programs, which come from a pepys
# release, and k3s.
#
# images/pepys/run-image-tests.sh builds the image from a stand-in context, in which each program
# is a probe that prints its ids and the modes and bytes of the paths it is given. It sets
# PEPYS_IMAGE and PEPYS_RUN, runs this suite, and removes the image.
#
#   bash images/pepys/run-image-tests.sh
#   CASE='modules' bash images/pepys/run-image-tests.sh

# starting a container on a cold Docker host can take most of the shared 30 seconds
export BATS_TEST_TIMEOUT=120

setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
  : "${PEPYS_IMAGE:?is unset: run this through images/pepys/run-image-tests.sh}"
  : "${PEPYS_RUN:?is unset: run this through images/pepys/run-image-tests.sh}"
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# run_probe <image> <program> <path>...: runs <program> with the pods' container security
run_probe() {
  local image="$1" program="$2"
  shift 2
  docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges \
    --entrypoint "/usr/local/bin/$program" "$image" "$@"
}

@test "it runs each program as the nonroot user from a read only executable file" {
  local program

  for program in pepys-host pepys-ingest pepys-api; do
    run_probe "$PEPYS_IMAGE" "$program" "/usr/local/bin/$program" > "$tree/$program.json"

    assert_equal "$(jq -r .uid "$tree/$program.json")" 65532
    assert_equal "$(jq -r .gid "$tree/$program.json")" 65532
    assert_equal "$(jq -r --arg p "/usr/local/bin/$program" '.paths[$p].mode' "$tree/$program.json")" 555
  done
}

@test "it lets the nonroot user read the modules and keeps them read only" {
  # COPY makes /modules itself 0755 whatever --chmod says; root owns it, so the user cannot write it
  run_probe "$PEPYS_IMAGE" pepys-host /modules /modules/ledger /modules/consumers.json /modules/ledger/0123abcd.wasm \
    > "$tree/modules.json"

  jq -S .paths "$tree/modules.json" | diff - <(
    jq -S . << 'JSON'
{
  "/modules": { "owner": 0, "mode": "755" },
  "/modules/ledger": { "owner": 0, "mode": "555" },
  "/modules/consumers.json": {
    "owner": 0,
    "mode": "444",
    "text": "{\"consumers\":[{\"name\":\"ledger\",\"module\":\"ledger/0123abcd.wasm\"}]}\n"
  },
  "/modules/ledger/0123abcd.wasm": {
    "owner": 0,
    "mode": "444",
    "text": "module bytes for the image test\n"
  }
}
JSON
  )
}
