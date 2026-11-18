# Evaluates services.model-gateway apart from any host's config and checks the units, the firewall
# admissions and the assertions it defines. Then it runs geoffcloud's gateway, the nixie release
# that the module pins, on geoffcloud's rendered config, against a stand-in model API
# (test-utils/run-stub-model-api.py, started by test-utils/start-stub-server.sh) in the build
# sandbox: the config moves only the model listener, the store, the override and the token file
# into the case's directory, and points each route at the stand-in. Each case runs on its own, in
# a fresh directory, under scripts/test-utils/shell/run-cases.sh.
# Run: bun run test:nixos model-gateway
{
  nixpkgs,
  imp,
  geoffcloud,
}:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;
  # the unit cases only read the binary's path, so it never runs
  stubGateway = pkgs.writeShellScriptBin "model-gateway" "exit 1";
  gateway = geoffcloud.config.services.model-gateway;

  prices = {
    input = 3;
    cache_write = 3.75;
    cache_write_1h = 6;
    cached_input = 0.3;
    output = 15;
  };
  settings = {
    enable = true;
    package = stubGateway;
    zone = "Europe/London";
    caps = {
      day = {
        dollars = 10;
        tokens = 1000;
      };
      month = {
        dollars = 100;
        tokens = 10000;
      };
    };
    modelListen = {
      interface = "podman0";
      address = "10.88.0.1";
      port = 8789;
      allowedSubnet = "10.88.0.0/16";
    };
    control = {
      port = 8790;
      tokenFile = "/run/fixture/control-token";
    };
    controlRelay = {
      interface = "cni0";
      address = "100.64.0.10";
      port = 8791;
      allowedSubnet = "10.42.0.0/16";
    };
    routes.sonnet = {
      model = "claude-sonnet-fixture";
      inherit prices;
    };
  };

  # inet cloud_host is an nftables table, so its module asserts nftables on, as geoffcloud runs it
  withNftables =
    config:
    config
    // {
      networking.nftables = {
        enable = true;
        flushRuleset = false;
      };
    };

  # starts geoffcloud's gateway on its rendered config, moved as the header says, with the token
  # file holding "fixture-token" and a trailing newline, and each plan route's login file and route
  # key ("fixture-route-key") in the case's directory, with no login file, so no refresh leaves the
  # sandbox; it sets gateway_port to the model listener's port; the stand-in must already run on
  # $port
  startGateway = ''
    printf 'fixture-token\n' > token
    # a plan route's key, which the case's login.json never exists beside, so the route needs a login
    printf 'fixture-route-key\n' > route-key
    # curl reads the header from a file, as the runbook passes the real token on stdin
    printf 'Authorization: Bearer %s\n' fixture-token > auth-header
    jq --arg upstream "http://127.0.0.1:$port" --arg dir "$PWD" '
      .listen = {hostname: "127.0.0.1", port: 0}
      | .store = "\($dir)/store.json"
      | .override = "\($dir)/override.json"
      | .control.tokenFile = "\($dir)/token"
      | .routes |= map_values(.upstream = $upstream)
      | .routes |= map_values(if .login then .login = {file: "\($dir)/login.json", routeKeyFile: "\($dir)/route-key"} else . end)' ${gateway.configFile} > config.yaml
    env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
      ${gateway.package}/bin/model-gateway serve --config config.yaml > gateway.log 2> gateway.err &
    gateway_pid=$!
    trap 'kill "$stub_pid" "$gateway_pid" 2> /dev/null || true' EXIT
    wait_for 10 "the gateway to start" grep -q '"event":"proxy.started"' gateway.log
    gateway_port=$(grep '"event":"proxy.started"' gateway.log | jq -r .port)
    control="http://127.0.0.1:${toString gateway.control.port}"
  '';

  # a whole, unstreamed Fable 5.2 reply with 1,000 input and 100 output tokens
  fableReply = builtins.toJSON {
    id = "msg_01stub";
    type = "message";
    role = "assistant";
    model = "claude-fable-5-2";
    content = [
      {
        type = "text";
        text = "ok";
      }
    ];
    stop_reason = "end_turn";
    stop_sequence = null;
    usage = {
      input_tokens = 1000;
      cache_creation_input_tokens = 0;
      cache_read_input_tokens = 0;
      output_tokens = 100;
    };
  };
  fableRequest = builtins.toJSON {
    model = "claude-fable-5-2";
    max_tokens = 100;
    messages = [
      {
        role = "user";
        content = "hi";
      }
    ];
  };

  cases = [
    {
      title = "it runs the gateway as its own user on the rendered config, with the token as a credential, once the token exists";
      script =
        let
          system = buildModuleSystem ../modules/model-gateway.nix (withNftables {
            services.model-gateway = settings;
          });
          service = system.config.systemd.services.model-gateway;
          configFile = system.config.services.model-gateway.configFile;
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            description = "nixie's model gateway";
            wantedBy = [ "multi-user.target" ];
            after = [
              "network-online.target"
              "imp-host.service"
            ];
            wants = [
              "network-online.target"
              "imp-host.service"
            ];
            unitConfig.ConditionPathExists = "/run/fixture/control-token";
            restartTriggers = [ "${configFile}" ];
            serviceConfig = {
              ExecStart = "${stubGateway}/bin/model-gateway serve --config ${configFile}";
              User = "model-gateway";
              Group = "model-gateway";
              StateDirectory = "model-gateway";
              StateDirectoryMode = "0700";
              LoadCredential = [ "control-token:/run/fixture/control-token" ];
              Restart = "always";
              RestartSec = 5;
              TimeoutStopSec = 45;
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictSUIDSGID = true;
              LockPersonality = true;
              CapabilityBoundingSet = "";
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
            };
          }}
          EOF
          jq -S . > actual <<'EOF'
          ${builtins.toJSON {
            inherit (service)
              description
              wantedBy
              after
              wants
              serviceConfig
              ;
            unitConfig = { inherit (service.unitConfig) ConditionPathExists; };
            restartTriggers = map toString service.restartTriggers;
          }}
          EOF
          assert_files_equal expected actual

          jq -S . > expected-config <<'EOF'
          ${builtins.toJSON {
            listen = {
              hostname = "10.88.0.1";
              port = 8789;
            };
            store = "/var/lib/model-gateway/store.json";
            periods.zone = "Europe/London";
            caps = settings.caps;
            control = {
              listen = {
                hostname = "127.0.0.1";
                port = 8790;
              };
              tokenFile = "/run/credentials/model-gateway.service/control-token";
            };
            countBySandbox = true;
            override = "/var/lib/model-gateway/override.json";
            routes.sonnet = {
              model = "claude-sonnet-fixture";
              upstream = "https://api.anthropic.com";
              inherit prices;
            };
          }}
          EOF
          jq -S . ${configFile} > actual-config
          assert_files_equal expected-config actual-config
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it relays the pod address to the loopback control listener, and admits one source to each listener";
      script =
        let
          system = buildModuleSystem ../modules/model-gateway.nix (withNftables {
            services.model-gateway = settings;
          });
          systemdPackage = system.config.systemd.package;
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            socket = {
              listenStreams = [ "100.64.0.10:8791" ];
              wantedBy = [ "sockets.target" ];
              socketConfig.FreeBind = true;
            };
            relay = {
              partOf = [ "model-gateway-control-relay.socket" ];
              serviceConfig = {
                ExecStart = "${systemdPackage}/lib/systemd/systemd-socket-proxyd 127.0.0.1:8790";
                DynamicUser = true;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                NoNewPrivileges = true;
                RestrictAddressFamilies = [
                  "AF_INET"
                  "AF_INET6"
                  "AF_UNIX"
                ];
                CapabilityBoundingSet = "";
              };
            };
            listen = {
              after = [ "model-gateway-control-relay.socket" ];
              restartTriggers = [ "100.64.0.10:8791" ];
              ExecStart = "${systemdPackage}/bin/systemctl restart model-gateway-control-relay.socket";
            };
            admissions = [
              {
                port = 8789;
                interface = "podman0";
                sourceCIDR = "10.88.0.0/16";
                destinationAddress = "10.88.0.1";
              }
              {
                port = 8791;
                interface = "cni0";
                sourceCIDR = "10.42.0.0/16";
                destinationAddress = "100.64.0.10";
              }
            ];
            podman0Ports = [ 8789 ];
            cni0Ports = [ 8791 ];
          }}
          EOF
          jq -S . > actual <<'EOF'
          ${
            let
              socket = system.config.systemd.sockets.model-gateway-control-relay;
              relay = system.config.systemd.services.model-gateway-control-relay;
              listen = system.config.systemd.services.model-gateway-control-relay-listen;
            in
            builtins.toJSON {
              socket = {
                inherit (socket) listenStreams wantedBy;
                socketConfig = { inherit (socket.socketConfig) FreeBind; };
              };
              relay = { inherit (relay) partOf serviceConfig; };
              listen = {
                inherit (listen) after;
                restartTriggers = map toString listen.restartTriggers;
                inherit (listen.serviceConfig) ExecStart;
              };
              admissions = system.config.networking.cloudHost.admissions;
              podman0Ports = system.config.networking.firewall.interfaces.podman0.allowedTCPPorts;
              cni0Ports = system.config.networking.firewall.interfaces.cni0.allowedTCPPorts;
            }
          }
          EOF
          assert_files_equal expected actual
        '';
    }
    {
      title = "it refuses a config with no route, or with the relay on the control port";
      script =
        let
          system = buildModuleSystem ../modules/model-gateway.nix (withNftables {
            services.model-gateway = settings // {
              routes = { };
              controlRelay = settings.controlRelay // {
                port = 8790;
              };
            };
          });
        in
        ''
          jq . > expected <<'EOF'
          ${builtins.toJSON [
            "services.model-gateway.routes names no route, and the gateway needs one."
            "services.model-gateway.controlRelay.port must differ from control.port: cloud_host drops the loopback's packets to an admitted port."
          ]}
          EOF
          jq . > actual <<'EOF'
          ${builtins.toJSON (collectFailedAssertions system)}
          EOF
          assert_files_equal expected actual
        '';
    }
    {
      title = "it loads each plan route key as a credential, renders the api, largest output and login of the route, and refuses a login on another api or outside the state directory";
      script =
        let
          planRoute = {
            api = "openai-responses";
            upstream = "https://chatgpt.com/backend-api/codex";
            model = "gpt-fixture";
            maxOutputTokens = 1000;
            inherit prices;
            login = {
              file = "/var/lib/model-gateway/login-plan.json";
              routeKeyFile = "/run/fixture/plan-route-key";
            };
          };
          system = buildModuleSystem ../modules/model-gateway.nix (withNftables {
            services.model-gateway = settings // {
              routes = settings.routes // {
                plan = planRoute;
              };
            };
          });
          refused = buildModuleSystem ../modules/model-gateway.nix (withNftables {
            services.model-gateway = settings // {
              routes = settings.routes // {
                plan = planRoute // {
                  api = null;
                  login = planRoute.login // {
                    file = "/srv/login-plan.json";
                  };
                };
              };
            };
          });
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            credentials = [
              "control-token:/run/fixture/control-token"
              "plan-route-key:/run/fixture/plan-route-key"
            ];
            routes = {
              sonnet = {
                model = "claude-sonnet-fixture";
                upstream = "https://api.anthropic.com";
                inherit prices;
              };
              plan = {
                api = "openai-responses";
                upstream = "https://chatgpt.com/backend-api/codex";
                model = "gpt-fixture";
                maxOutputTokens = 1000;
                inherit prices;
                login = {
                  file = "/var/lib/model-gateway/login-plan.json";
                  routeKeyFile = "/run/credentials/model-gateway.service/plan-route-key";
                };
              };
            };
            failed = [ ];
            refused = [
              "services.model-gateway.routes: a route with a login speaks openai-responses, the API of ChatGPT's Codex backend."
              "services.model-gateway.routes: a login file lives in /var/lib/model-gateway, the only folder the unit may write, because each refresh rewrites it."
            ];
          }}
          EOF
          jq -S --slurpfile config ${system.config.services.model-gateway.configFile} '.routes = $config[0].routes' > actual <<'EOF'
          ${builtins.toJSON {
            credentials = system.config.systemd.services.model-gateway.serviceConfig.LoadCredential;
            routes = null;
            failed = collectFailedAssertions system;
            refused = collectFailedAssertions refused;
          }}
          EOF
          assert_files_equal expected actual
        '';
    }
    {
      title = "it renders the geoffcloud config with the nixie zone, the caps, a loopback control listener and a priced route per nixie profile";
      script =
        let
          fable52 = {
            input = 8;
            cache_write = 10;
            cache_write_1h = 16;
            cached_input = 0.2;
            output = 40;
          };
          fable51 = {
            input = 10;
            cache_write = 12.5;
            cache_write_1h = 20;
            cached_input = 0.25;
            output = 50;
          };
          opus55 = {
            input = 4;
            cache_write = 5;
            cache_write_1h = 8;
            cached_input = 0.2;
            output = 20;
          };
          opus4 = {
            input = 5;
            cache_write = 6.25;
            cache_write_1h = 10;
            cached_input = 0.5;
            output = 25;
          };
          sonnet55 = {
            input = 2;
            cache_write = 2.5;
            cache_write_1h = 4;
            cached_input = 0.1;
            output = 10;
          };
          haiku55 = {
            input = 0.1;
            cache_write = 0.125;
            cache_write_1h = 0.2;
            cached_input = 0.01;
            output = 0.5;
            long_prompt = {
              over_tokens = 100000;
              input = 0.5;
              cache_write = 0.625;
              cache_write_1h = 1;
              cached_input = 0.05;
              output = 2.5;
            };
          };
          route = model: prices: {
            inherit model prices;
            upstream = "https://api.anthropic.com";
          };
          # each model's pinned OpenRouter endpoint and its price, as the host config gives them
          openrouterRoute = model: providerPin: prices: {
            inherit model providerPin prices;
            upstream = "https://openrouter.ai/api";
          };
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            listen = {
              hostname = "10.88.0.1";
              port = 8789;
            };
            store = "/var/lib/model-gateway/store.json";
            periods.zone = "Australia/Sydney";
            caps = {
              day = {
                dollars = 120;
                tokens = 160000000;
              };
              month = {
                dollars = 1200;
                tokens = 1200000000;
              };
            };
            control = {
              listen = {
                hostname = "127.0.0.1";
                port = 8790;
              };
              tokenFile = "/run/credentials/model-gateway.service/control-token";
            };
            countBySandbox = true;
            override = "/var/lib/model-gateway/override.json";
            routes = {
              fable-5-2 = route "claude-fable-5-2" fable52;
              fable-5-1 = route "claude-fable-5-1" fable51;
              opus-5-5 = route "claude-opus-5-5" opus55;
              opus-4-6 = route "claude-opus-4-6" opus4;
              opus-4-5 = route "claude-opus-4-5" opus4;
              sonnet-5-5 = route "claude-sonnet-5-5" sonnet55;
              sonnet-5-5-high = route "claude-sonnet-5-5" sonnet55;
              haiku-5-5 = route "claude-haiku-5-5" haiku55;
              haiku-5-5-low = route "claude-haiku-5-5" haiku55;
              gemini-4-carbon = openrouterRoute "google/gemini-4-carbon" "google-ai-studio" {
                input = 2;
                cache_write = 2.1875;
                cache_write_1h = 2.1875;
                cached_input = 0.1;
                output = 10;
              };
              gpt-6-2-sol = openrouterRoute "openai/gpt-6.2-sol" "openai" {
                input = 2;
                cache_write = 2.5;
                cache_write_1h = 2.5;
                cached_input = 0.1;
                output = 10;
                long_prompt = {
                  over_tokens = 272000;
                  input = 4;
                  cache_write = 5;
                  cache_write_1h = 5;
                  cached_input = 0.2;
                  output = 15;
                };
              };
              kimi-k3-1-pro = openrouterRoute "moonshotai/kimi-k3.1-pro" "fireworks" {
                input = 2;
                cache_write = 2;
                cache_write_1h = 2;
                cached_input = 0.2;
                output = 10;
              };
              glm-5-3 = openrouterRoute "z-ai/glm-5.3" "tenstorrent/fp8" {
                input = 0.6;
                cache_write = 0.6;
                cache_write_1h = 0.6;
                cached_input = 0.1;
                output = 2.5;
              };
              grok-4-7 = openrouterRoute "x-ai/grok-4.7" "xai" {
                input = 2.2;
                cache_write = 2.2;
                cache_write_1h = 2.2;
                cached_input = 0.55;
                output = 6.6;
                long_prompt = {
                  over_tokens = 200000;
                  input = 4.4;
                  cache_write = 4.4;
                  cache_write_1h = 4.4;
                  cached_input = 1.1;
                  output = 13.2;
                };
              };
              qwen4-max = openrouterRoute "qwen/qwen4-max" "alibaba" {
                input = 1.425;
                cache_write = 1.78125;
                cache_write_1h = 1.78125;
                cached_input = 0.07125;
                output = 4.275;
              };
              mistral-large-4 = openrouterRoute "mistralai/mistral-large-4-0" "mistral/zdr" {
                input = 0.7;
                cache_write = 0.7;
                cache_write_1h = 0.7;
                cached_input = 0.07;
                output = 2.1;
              };
              inkling-2-small = openrouterRoute "thinkingmachines/inkling-2-small" "together" {
                input = 0.3;
                cache_write = 0.3;
                cache_write_1h = 0.3;
                cached_input = 0.03;
                output = 1;
              };
              deepseek-v4-1-flash = openrouterRoute "deepseek/deepseek-v4.1-flash-1017" "nebius/fp8" {
                input = 0.12;
                cache_write = 0.12;
                cache_write_1h = 0.12;
                cached_input = 0.0024;
                output = 0.48;
              };
              gpt-6-2-astra = openrouterRoute "openai/gpt-6.2-astra" "openai" {
                input = 8;
                cache_write = 10;
                cache_write_1h = 10;
                cached_input = 0.4;
                output = 40;
                long_prompt = {
                  over_tokens = 272000;
                  input = 16;
                  cache_write = 20;
                  cache_write_1h = 20;
                  cached_input = 0.8;
                  output = 60;
                };
              };
              gemini-4-hydrogen = openrouterRoute "google/gemini-4-hydrogen" "google-ai-studio" {
                input = 1.5;
                cache_write = 1.583333;
                cache_write_1h = 1.583333;
                cached_input = 0.075;
                output = 7.5;
              };
              muse-wonder = openrouterRoute "meta/muse-wonder" "meta" {
                input = 4;
                cache_write = 4;
                cache_write_1h = 4;
                cached_input = 0.2;
                output = 20;
              };
              hy4 = openrouterRoute "tencent/hy4" "tencent/fp4" {
                input = 0.417;
                cache_write = 0.417;
                cache_write_1h = 0.417;
                cached_input = 0.021;
                output = 1.2505;
              };
              pareto-26-10 = openrouterRoute "unbiased/pareto-26.10" "unbiased" {
                input = 0.8;
                cache_write = 0.8;
                cache_write_1h = 0.8;
                cached_input = 0.03;
                output = 3.2;
              };
              aion-3-5 = openrouterRoute "aion-labs/aion-3.5" "aion-labs" {
                input = 3;
                cache_write = 3;
                cache_write_1h = 3;
                cached_input = 0.75;
                output = 6;
              };
              # the plan route, whose key the unit loads as a credential
              codex-plan = {
                api = "openai-responses";
                upstream = "https://chatgpt.com/backend-api/codex";
                model = "gpt-6-luna";
                maxOutputTokens = 128000;
                prices = {
                  input = 0.1;
                  cache_write = 0.125;
                  cache_write_1h = 0.125;
                  cached_input = 0.01;
                  output = 0.5;
                  long_prompt = {
                    over_tokens = 272000;
                    input = 0.2;
                    cache_write = 0.25;
                    cache_write_1h = 0.25;
                    cached_input = 0.02;
                    output = 0.75;
                  };
                };
                login = {
                  file = "/var/lib/model-gateway/chatgpt-login-codex-plan.json";
                  routeKeyFile = "/run/credentials/model-gateway.service/codex-plan-route-key";
                };
              };
            };
          }}
          EOF
          jq -S . ${gateway.configFile} > actual
          assert_files_equal expected actual
        '';
    }
    {
      title = "it answers the geoffcloud control listener only with the token, in the nixie zone, and refuses a limit above the cap";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} /v1/messages ${lib.escapeShellArg fableReply} "$PWD/requests"
        ${startGateway}

        curl -s -o unauthorized -w '%{http_code}' "$control/status" > unauthorized-status
        curl -s -o status -w '%{http_code}' -H @auth-header "$control/status" > status-status
        curl -s -o above-cap -w '%{http_code}' -X PUT -H @auth-header \
          -d '{"day":{"dollars":121,"tokens":80000000},"month":{"dollars":600,"tokens":600000000}}' \
          "$control/limits" > above-cap-status

        assert_equals 401 "$(cat unauthorized-status)" "the tokenless status's code"
        assert_equals 200 "$(cat status-status)" "the status's code"
        assert_equals '{"zone":"Australia/Sydney","lost":false,"day":{"limit":null,"cap":{"dollars":120,"tokens":160000000}},"month":{"limit":null,"cap":{"dollars":1200,"tokens":1200000000}},"tripped":null}' \
          "$(jq -c '{zone, lost, day: (.periods.day | {limit, cap}), month: (.periods.month | {limit, cap}), tripped}' status)" "the status"
        assert_equals 409 "$(cat above-cap-status)" "the above-cap limit's code"
        assert_equals '{"error":"above_cap","period":"day","cap":{"dollars":120,"tokens":160000000}}' "$(jq -c . above-cap)" "the refusal"
        assert_files_equal /dev/null gateway.err
      '';
    }
    {
      title = "it refuses a request from a sandbox that nixie never registered, and sends nothing upstream";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} /v1/messages ${lib.escapeShellArg fableReply} "$PWD/requests"
        ${startGateway}
        : > requests
        curl -s -o /dev/null -X PUT -H @auth-header \
          -d '{"day":{"dollars":60,"tokens":80000000},"month":{"dollars":600,"tokens":600000000}}' "$control/limits"

        curl -s -o reply -w '%{http_code}' -X POST "http://127.0.0.1:$gateway_port/nixie-0a1b2c/fable-5-2/v1/messages" \
          -H 'content-type: application/json' -d ${lib.escapeShellArg fableRequest} > status

        assert_equals 403 "$(cat status)" "the gateway's status"
        assert_equals permission_error "$(jq -r .error.type reply)" "the error's type"
        assert_files_equal /dev/null requests
        assert_files_equal /dev/null gateway.err
      '';
    }
    {
      title = "it counts a Fable 5.2 request of a registered sandbox at the Fable 5.2 prices in the day, the month and the sandbox";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} /v1/messages ${lib.escapeShellArg fableReply} "$PWD/requests"
        ${startGateway}
        curl -s -o /dev/null -X PUT -H @auth-header \
          -d '{"day":{"dollars":60,"tokens":80000000},"month":{"dollars":600,"tokens":600000000}}' "$control/limits"
        curl -s -o /dev/null -X PUT -H @auth-header -d '{"limit":null}' "$control/sandboxes/nixie-0a1b2c"

        curl -s -o reply -w '%{http_code}' -X POST "http://127.0.0.1:$gateway_port/nixie-0a1b2c/fable-5-2/v1/messages" \
          -H 'content-type: application/json' -d ${lib.escapeShellArg fableRequest} > status
        wait_for 10 "the reply's count" jq -e '.periods.day.tokens > 0' store.json

        assert_equals 200 "$(cat status)" "the gateway's status"
        # 1,000 input tokens at $8 and 100 output tokens at $40 per million
        assert_equals '{"day":{"dollars":0.012,"tokens":1100},"month":{"dollars":0.012,"tokens":1100},"sandbox":{"dollars":0.012,"tokens":1100}}' \
          "$(jq -c '{day: (.periods.day | {dollars, tokens}), month: (.periods.month | {dollars, tokens}), sandbox: (.sandboxes["nixie-0a1b2c"] | {dollars, tokens})}' store.json)" "the count"
        assert_equals "POST /v1/messages" "$(cat requests)" "the stand-in's requests"
        assert_files_equal /dev/null gateway.err
      '';
    }
    {
      title = "it lists the geoffcloud plan route as needing a login, refuses a plan request with another key with a 403 and one with the key with a 401, and sends nothing upstream";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} /responses '{}' "$PWD/requests"
        ${startGateway}
        : > requests
        curl -s -o /dev/null -X PUT -H @auth-header \
          -d '{"day":{"dollars":60,"tokens":80000000},"month":{"dollars":600,"tokens":600000000}}' "$control/limits"
        curl -s -o /dev/null -X PUT -H @auth-header -d '{"limit":null}' "$control/sandboxes/nixie-0a1b2c"
        plan_request='{"model":"gpt-6-luna","input":"hi","stream":true}'
        printf 'Authorization: Bearer %s\n' another-key > wrong-key-header
        printf 'Authorization: Bearer %s\n' fixture-route-key > route-key-header

        curl -s -o logins -w '%{http_code}' -H @auth-header "$control/chatgpt-logins" > logins-status
        curl -s -o wrong-key -w '%{http_code}' -X POST "http://127.0.0.1:$gateway_port/nixie-0a1b2c/codex-plan/responses" \
          -H @wrong-key-header -H 'content-type: application/json' -d "$plan_request" > wrong-key-status
        curl -s -o no-login -w '%{http_code}' -X POST "http://127.0.0.1:$gateway_port/nixie-0a1b2c/codex-plan/responses" \
          -H @route-key-header -H 'content-type: application/json' -d "$plan_request" > no-login-status

        assert_equals 200 "$(cat logins-status)" "the logins' code"
        assert_equals '["codex-plan"]' "$(jq -c keys logins)" "the plan routes"
        assert_equals '{"status":"needs_login","reason":null}' "$(jq -c '.["codex-plan"] | {status, reason}' logins)" "the plan route's login"
        assert_equals 403 "$(cat wrong-key-status)" "the code for another key"
        assert_equals 401 "$(cat no-login-status)" "the code with no login"
        assert_files_equal /dev/null requests
        assert_files_equal /dev/null gateway.err
      '';
    }
  ];
in
pkgs.runCommand "model-gateway-check"
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
    source ${pkgs.writeText "model-gateway-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
