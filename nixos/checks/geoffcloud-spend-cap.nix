# Runs geoffcloud's counting proxy, the nixie release that services.preview.spendCap pins, with
# the model and prices that geoffcloud's preview unit hands the service, against a stand-in model
# API (test-utils/run-stub-model-api.py, started by test-utils/start-stub-server.sh) in the build
# sandbox, and checks the count that one reply adds to the proxy's store. Each case runs on its
# own, in a fresh directory, with its own stand-in, proxy and store, under
# test-support/shell/run-cases.sh.
# Run: bun run test:nixos geoffcloud-spend-cap
{
  pkgs,
  imp,
  geoffcloud,
}:
let
  lib = pkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  environment = geoffcloud.config.systemd.services.preview.environment;

  # starts the proxy on the config the preview service writes for one imp, routed to the stand-in
  # on $port, and sets proxy_port to the port it reports
  startProxy = ''
    jq -n \
      --arg upstream "http://127.0.0.1:$port" \
      --arg store "$PWD/count.json" \
      --arg model ${lib.escapeShellArg environment.PREVIEW_SPEND_MODEL} \
      --argjson prices ${lib.escapeShellArg environment.PREVIEW_SPEND_PRICES} \
      --argjson dollars ${environment.PREVIEW_SPEND_LIMIT_DOLLARS} \
      '{listen: {hostname: "127.0.0.1", port: 0}, store: $store, limits: {dollars: $dollars},
        routes: {"pv-check": {upstream: $upstream, model: $model, prices: $prices}}}' > config.json
    env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
      ${environment.PREVIEW_SPEND_PROXY} --config config.json > proxy.log 2> proxy.err &
    proxy_pid=$!
    trap 'kill "$stub_pid" "$proxy_pid" 2> /dev/null || true' EXIT
    wait_for 10 "the proxy to start" grep -q '"event":"proxy.started"' proxy.log
    proxy_port=$(jq -r 'select(.event == "proxy.started") | .port' proxy.log)
  '';

  cases = [
    {
      title = "it counts a Haiku 5.5 call whose prompt passes 100,000 tokens at the long-prompt prices";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} /v1/messages \
          '{"id":"msg_01stub","type":"message","role":"assistant","model":"claude-haiku-5-5","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":100001,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1000}}' \
          "$PWD/requests"
        ${startProxy}

        curl -s -o reply -w '%{http_code}' -X POST "http://127.0.0.1:$proxy_port/pv-check/v1/messages" \
          -H 'content-type: application/json' \
          -d '{"model":"claude-haiku-5-5","max_tokens":1000,"messages":[{"role":"user","content":"hi"}]}' > status
        wait_for 10 "the reply's count" jq -e '.tokens > 0' count.json

        assert_equals 200 "$(cat status)" "the proxy's status"
        # 100,001 input tokens at $0.50 and 1,000 output tokens at $2.50 per million
        assert_equals '{"dollars":0.0525005,"tokens":101001}' "$(cat count.json)" "the count"
        assert_equals "POST /v1/messages" "$(cat requests)" "the stand-in's requests"
        assert_files_equal /dev/null proxy.err
      '';
    }
    {
      title = "it counts a Haiku 5.5 call whose prompt is 100,000 tokens at the base prices";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} /v1/messages \
          '{"id":"msg_01stub","type":"message","role":"assistant","model":"claude-haiku-5-5","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":100000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1000}}' \
          "$PWD/requests"
        ${startProxy}

        curl -s -o reply -w '%{http_code}' -X POST "http://127.0.0.1:$proxy_port/pv-check/v1/messages" \
          -H 'content-type: application/json' \
          -d '{"model":"claude-haiku-5-5","max_tokens":1000,"messages":[{"role":"user","content":"hi"}]}' > status
        wait_for 10 "the reply's count" jq -e '.tokens > 0' count.json

        assert_equals 200 "$(cat status)" "the proxy's status"
        # 100,000 input tokens at $0.10 and 1,000 output tokens at $0.50 per million
        assert_equals '{"dollars":0.0105,"tokens":101000}' "$(cat count.json)" "the count"
        assert_equals "POST /v1/messages" "$(cat requests)" "the stand-in's requests"
        assert_files_equal /dev/null proxy.err
      '';
    }
    {
      title = "it counts a Haiku 5.5 call whose cache reads take its prompt past 100,000 tokens at the long-prompt prices";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} /v1/messages \
          '{"id":"msg_01stub","type":"message","role":"assistant","model":"claude-haiku-5-5","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":99001,"output_tokens":100}}' \
          "$PWD/requests"
        ${startProxy}

        curl -s -o reply -w '%{http_code}' -X POST "http://127.0.0.1:$proxy_port/pv-check/v1/messages" \
          -H 'content-type: application/json' \
          -d '{"model":"claude-haiku-5-5","max_tokens":1000,"messages":[{"role":"user","content":"hi"}]}' > status
        wait_for 10 "the reply's count" jq -e '.tokens > 0' count.json

        assert_equals 200 "$(cat status)" "the proxy's status"
        # 1,000 input tokens at $0.50, 99,001 cache reads at $0.05 and 100 output tokens at $2.50
        # per million
        assert_equals '{"dollars":0.00570005,"tokens":100101}' "$(cat count.json)" "the count"
        assert_equals "POST /v1/messages" "$(cat requests)" "the stand-in's requests"
        assert_files_equal /dev/null proxy.err
      '';
    }
  ];
in
pkgs.runCommand "geoffcloud-spend-cap-check"
  {
    nativeBuildInputs = [
      pkgs.curl
      pkgs.diffutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.python3
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${testLib}/wait-for.sh
    source ${./test-utils/start-stub-server.sh}
    source ${pkgs.writeText "geoffcloud-spend-cap-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
