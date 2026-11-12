#!/usr/bin/env bash
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
# shell-suite: pepys-image
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"

# run_probe <image> <program> <path>...: runs <program> with the pods' container security
run_probe() {
  local image="$1" program="$2"
  shift 2
  docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges \
    --entrypoint "/usr/local/bin/$program" "$image" "$@"
}

it_runs_each_program_as_the_nonroot_user_from_a_read_only_executable_file() {
  local image="$1" program
  create_case_tree

  for program in pepys-host pepys-ingest pepys-api; do
    run_probe "$image" "$program" "/usr/local/bin/$program" > "$tree/$program.json"

    assert_equals 65532 "$(jq -r .uid "$tree/$program.json")" "$program uid"
    assert_equals 65532 "$(jq -r .gid "$tree/$program.json")" "$program gid"
    assert_equals 555 "$(jq -r --arg p "/usr/local/bin/$program" '.paths[$p].mode' "$tree/$program.json")" "$program mode"
  done
}

it_lets_the_nonroot_user_read_the_modules_and_keeps_them_read_only() {
  local image="$1"
  create_case_tree

  # COPY makes /modules itself 0755 whatever --chmod says; root owns it, so the user cannot write it
  run_probe "$image" pepys-host /modules /modules/ledger /modules/consumers.json /modules/ledger/0123abcd.wasm \
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

: "${PEPYS_IMAGE:?is unset: run this through images/pepys/run-image-tests.sh}"
: "${PEPYS_RUN:?is unset: run this through images/pepys/run-image-tests.sh}"
run_cases "$PEPYS_IMAGE"
