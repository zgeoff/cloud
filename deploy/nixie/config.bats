#!/usr/bin/env bats
# bats file_tags=suite:nixie-config
# Checks deploy/nixie/config.yaml with the validation of the nixie image that the stack config pins
# as nixie.image, run locally with Docker. It touches no cluster and no cloud account.
#
# It renders the config as the nixie ConfigMap holds it (infra/cluster/create-nixie.ts), mounts it at
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
#   CASE='context cap' bash scripts/run-bats.sh nixie-config

# each case starts a container, which a cold host can take longer than 30 seconds over
export BATS_TEST_TIMEOUT=120

# Boot data every case needs: the nixie image the stack config pins (nixie.image), pulled once.
setup_file() {
  load '../../scripts/src/test-utils/bats/setup'
  local repo
  repo="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  image="$(cd "$repo" && bun -e 'console.log(Bun.YAML.parse(await Bun.file("infra/Pulumi.prod.yaml").text()).config["geoff-cloud:nixie"].image)')"
  docker pull -q "$image" > /dev/null
  export image
}

setup() {
  load '../../scripts/src/test-utils/bats/setup'
  umask 022
  repo="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  tree="$BATS_TEST_TMPDIR"
  name="nixie-config-$(basename "$BATS_RUN_TMPDIR")-$BATS_TEST_NUMBER"
}

teardown() {
  stop_timeout_watchdog
  docker rm -f "$name" > /dev/null 2>&1 || true
}

# render_config <source> <out>: the config as infra renders it into nixie's ConfigMap
render_config() {
  (cd "$repo" && SOURCE="$1" bun -e '
    import { exposure, topology } from "@zgeoff/cloud-topology";
    import { buildNixieImpConfig } from "./infra/shared/build-nixie-imp-config.ts";
    import { buildNixieSpendStopConfig } from "./infra/shared/build-nixie-spend-stop-config.ts";
    import { renderNixieConfig } from "./infra/shared/render-nixie-config.ts";
    const text = await Bun.file(process.env.SOURCE ?? "").text();
    process.stdout.write(renderNixieConfig(text, {
      imp: buildNixieImpConfig(topology),
      spendStop: buildNixieSpendStopConfig(topology, exposure),
    }));
  ') > "$2"
}

# run_health <name> <image> <config>: the image's health command, under the nixie container's
# user and security settings (infra/cluster/build-nixie-spec.ts)
run_health() {
  docker run --rm --name "$1" --user 10001:10001 --read-only --security-opt no-new-privileges \
    --cap-drop ALL --network none -v "$3:/etc/nixie/config.yaml:ro" "$2" health
}

@test "it loads the rendered config in the pinned nixie" {
  render_config "$repo/deploy/nixie/config.yaml" "$tree/config.yaml"

  run -1 --separate-stderr run_health "$name" "$image" "$tree/config.yaml"

  refute_stderr
  sed -E 's/"time":"[^"]+",//' <<< "$output" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
{"event":"command.failed","command":"health","error":"TypeError","message":"ECONNREFUSED: Unable to connect. Is the computer able to access the url?"}
EOF
}

@test "it shows the refusal of a context cap above the cli window" {
  # a copy of the conversation's profile on an ID the CLI's catalog lacks, which gets the
  # 200000-token window, with a 400000 cap
  (cd "$repo" && bun -e '
    const config = Bun.YAML.parse(await Bun.file("deploy/nixie/config.yaml").text());
    const profile = config.models.profiles[config.models.roles.conversation];
    config.models.profiles["test-refused"] = { ...profile, model: "claude-test-1", context_tokens: 400000 };
    console.log(Bun.YAML.stringify(config, null, 2));
  ') > "$tree/source.yaml"
  render_config "$tree/source.yaml" "$tree/config.yaml"

  run -1 --separate-stderr run_health "$name" "$image" "$tree/config.yaml"

  refute_stderr
  sed -E 's/"time":"[^"]+",//' <<< "$output" > "$tree/out.normal"
  diff - "$tree/out.normal" << 'EOF'
{"event":"command.failed","command":"health","error":"Error","message":"nixie refuses the deployment configuration in /etc/nixie/config.yaml:\nmodels.profiles.test-refused.context_tokens: the context cap of 400000 tokens is larger than the 200000-token window the Claude CLI assumes for claude-test-1"}
EOF
}
