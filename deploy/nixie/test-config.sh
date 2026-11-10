#!/usr/bin/env bash
# Checks deploy/nixie/config.yaml with the validation of the nixie image that the stack config pins
# as nixie.image, run locally with Docker. It touches no cluster and no cloud account.
#
# It renders the config as the nixie ConfigMap holds it (infra/cluster/nixie.ts), mounts it at
# nixie's default config path, and runs the image's `health` command with nixie's uid, a read-only
# root, no capabilities and no network. `health` loads the config through the same validation that
# `serve` runs at start, then asks the server for its health. No server runs, so a config that
# nixie accepts ends in a refused connection, and one that nixie refuses ends in its refusal.
# What this proves: the pinned nixie accepts the config's schema, profiles and roles. What it does
# not prove: the secrets, the sandbox manifest and the services that `serve` reaches after the
# config loads.
#
# `bun run test:nixie-config` runs it; one case alone:
#
#   CASE='context cap' bash deploy/nixie/test-config.sh
# shell-suite: nixie-config
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-status.sh"

cleanup='docker rm -f "$name" > /dev/null 2>&1 || true'

it_loads_the_rendered_config_in_the_pinned_nixie() {
  local image="$1" status=0
  name="nixie-config-$2-$BASHPID"
  create_case_tree "$cleanup"
  render_config "$repo/deploy/nixie/config.yaml" "$tree/config.yaml"

  run_health "$name" "$image" "$tree/config.yaml" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  sed -E 's/"time":"[^"]+",//' "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
{"event":"command.failed","command":"health","error":"TypeError","message":"ECONNREFUSED: Unable to connect. Is the computer able to access the url?"}
EOF
  assert_status 1 "$status"
}

it_shows_the_refusal_of_a_context_cap_above_the_cli_window() {
  local image="$1" status=0
  name="nixie-config-$2-$BASHPID"
  create_case_tree "$cleanup"
  # an ID the CLI's catalog lacks gets its 200000-token window, under opus-5-5's 400000 cap
  sed 's/model: claude-opus-5-5$/model: claude-test-1/' "$repo/deploy/nixie/config.yaml" > "$tree/source.yaml"
  render_config "$tree/source.yaml" "$tree/config.yaml"

  run_health "$name" "$image" "$tree/config.yaml" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  sed -E 's/"time":"[^"]+",//' "$tree/out" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
{"event":"command.failed","command":"health","error":"Error","message":"nixie refuses the deployment configuration in /etc/nixie/config.yaml:\nmodels.profiles.opus-5-5.context_tokens: the context cap of 400000 tokens is larger than the 200000-token window the Claude CLI assumes for claude-test-1"}
EOF
  assert_status 1 "$status"
}

# render_config <source> <out>: the config as infra renders it into nixie's ConfigMap
render_config() {
  (cd "$repo" && SOURCE="$1" bun -e '
    import { topology } from "@zgeoff/cloud-topology";
    import { buildNixieImpConfig } from "./infra/shared/build-nixie-imp-config.ts";
    import { renderNixieConfig } from "./infra/shared/render-nixie-config.ts";
    const text = await Bun.file(process.env.SOURCE ?? "").text();
    process.stdout.write(renderNixieConfig(text, buildNixieImpConfig(topology)));
  ') > "$2"
}

# run_health <name> <image> <config>: the image's health command, under the nixie container's
# user and security settings (infra/cluster/build-nixie-spec.ts)
run_health() {
  docker run --rm --name "$1" --user 10001:10001 --read-only --security-opt no-new-privileges \
    --cap-drop ALL --network none -v "$3:/etc/nixie/config.yaml:ro" "$2" health
}

# Boot data every case needs: the nixie image the stack config pins (nixie.image), pulled once.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="$(cd "$repo" && bun -e 'console.log(Bun.YAML.parse(await Bun.file("infra/Pulumi.prod.yaml").text()).config["geoff-cloud:nixie"].image)')"
docker pull -q "$image" > /dev/null
run="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
run_cases "$image" "$run"
