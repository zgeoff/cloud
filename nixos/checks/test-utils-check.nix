# Tests the checks' shared test utilities: the shell helper in scripts/src/test-utils/shell that the
# checks source (wait-for.sh), and the Nix helpers and stand-ins in nixos/checks/test-utils. The
# checks that use them build this first, so a broken utility fails every check that relies on it
# instead of passing silently. renderCases' own tests come first, as a plain .bats file, since the
# cases after them are rendered by it; a failing one stops the build. Every other test is a case
# renderCases renders into a .bats file that bats runs, each in a fresh directory of its own, with
# the bats-support and bats-assert libraries. The cases are titled "it <unit> ...".
{ pkgs, imp }:
let
  lib = pkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  renderCases = import ./test-utils/render-cases.nix {
    inherit lib;
    sources = [ ./test-utils/start-stub-server.sh ];
  };
  collectCaseRejections = import ./test-utils/collect-case-rejections.nix { inherit lib; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;
  findBunRelease = import ./test-utils/find-bun-release.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  stubSqlite3 = import ./test-utils/build-stub-sqlite3.nix { inherit pkgs; };
  stubIntegritySqlite3 = import ./test-utils/build-stub-integrity-sqlite3.nix { inherit pkgs; };
  stubBlockingSqlite3 = import ./test-utils/build-stub-blocking-sqlite3.nix { inherit pkgs; };
  stubSystemctl = import ./test-utils/build-stub-systemctl.nix { inherit pkgs; };
  stubCmp = import ./test-utils/build-stub-cmp.nix { inherit pkgs; };
  stubCurl = import ./test-utils/build-stub-curl.nix { inherit pkgs; };
  stubSleep = import ./test-utils/build-stub-sleep.nix { inherit pkgs; };
  stubImpHostPodman = import ./test-utils/build-stub-imp-host-podman.nix { inherit pkgs; };
  buildStorePathGaps = import ./test-utils/build-store-path-gaps.nix { inherit pkgs; };
  stubImpzHostImage = import ./test-utils/build-stub-impz-host-image.nix { inherit pkgs; };
  stubAgentImageBun = import ./test-utils/build-stub-agent-image-bun.nix { inherit pkgs; };
  stubOpRead = import ./test-utils/build-stub-op-read.nix { inherit pkgs; } {
    "op://vault/item/field" = "a value with spaces";
    "op://vault/item/other" = "other";
  };
  # the Bun of the pinned imp's host/Dockerfile, from the release of the Bun it pins: the image
  # digest of the oven/bun stage and the hash of the release's bun-linux-x64.zip
  impBunRelease = findBunRelease {
    "1.4.4" = {
      digest = "sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d";
      hash = "sha256-v4zL+ysLgBWeD5ptFcVTF63YB3U028YTCj7bUvzLOVw=";
    };
  } (builtins.readFile "${imp}/host/Dockerfile");

  cases = [
    {
      title = "it buildShellLibSource holds the shell helper the checks read and no other file";
      script = ''
        ls -A ${testLib} > listing

        diff -u - listing <<'EOF'
        wait-for.sh
        EOF
      '';
    }
    {
      title = "it collectFailedAssertions lists the messages of the failing assertions, in order";
      script = ''
        failed=${
          lib.escapeShellArg (
            builtins.toJSON (collectFailedAssertions {
              config.assertions = [
                {
                  assertion = false;
                  message = "first";
                }
                {
                  assertion = true;
                  message = "holds";
                }
                {
                  assertion = false;
                  message = "second";
                }
              ];
            })
          )
        }

        assert_equal "$failed" '["first","second"]'
      '';
    }
    {
      title = "it collectFailedAssertions lists nothing when every assertion holds";
      script = ''
        failed=${
          lib.escapeShellArg (
            builtins.toJSON (collectFailedAssertions {
              config.assertions = [
                {
                  assertion = true;
                  message = "holds";
                }
              ];
            })
          )
        }

        assert_equal "$failed" '[]'
      '';
    }
    {
      title = "it findBunRelease gives the version and zip hash of the release at the digest of the oven/bun stage";
      script = ''
        release=${
          lib.escapeShellArg (
            builtins.toJSON (
              findBunRelease
                {
                  "9.1.0" = {
                    digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
                    hash = "sha256-oldZipHash=";
                  };
                  "9.2.0" = {
                    digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222";
                    hash = "sha256-newZipHash=";
                  };
                }
                ''
                  FROM oven/bun:9.2.0@sha256:2222222222222222222222222222222222222222222222222222222222222222 AS bun
                  FROM debian:trixie-slim@sha256:3333333333333333333333333333333333333333333333333333333333333333 AS runtime
                  FROM bun AS compile
                ''
            )
          )
        }

        assert_equal "$release" '{"hash":"sha256-newZipHash=","version":"9.2.0"}'
      '';
    }
    {
      title = "it findBunRelease names a Bun version it holds no release of";
      script = ''
        release=${
          lib.escapeShellArg (
            builtins.toJSON (
              findBunRelease
                {
                  "9.1.0" = {
                    digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
                    hash = "sha256-oldZipHash=";
                  };
                }
                ''
                  FROM oven/bun:9.3.0@sha256:4444444444444444444444444444444444444444444444444444444444444444 AS bun
                ''
            )
          )
        }

        assert_equal "$release" '{"error":"no release of Bun 9.3.0: add its image digest and the hash of its zip"}'
      '';
    }
    {
      title = "it findBunRelease names the digest of an oven/bun stage at another digest than its release";
      script = ''
        release=${
          lib.escapeShellArg (
            builtins.toJSON (
              findBunRelease
                {
                  "9.1.0" = {
                    digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
                    hash = "sha256-oldZipHash=";
                  };
                }
                ''
                  FROM oven/bun:9.1.0@sha256:5555555555555555555555555555555555555555555555555555555555555555 AS bun
                ''
            )
          )
        }

        assert_equal "$release" '{"error":"the Dockerfile pins Bun 9.1.0 at sha256:5555555555555555555555555555555555555555555555555555555555555555, not at sha256:1111111111111111111111111111111111111111111111111111111111111111"}'
      '';
    }
    {
      title = "it findBunRelease counts the oven/bun stages of a Dockerfile with two";
      script = ''
        release=${
          lib.escapeShellArg (
            builtins.toJSON (
              findBunRelease
                {
                  "9.1.0" = {
                    digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
                    hash = "sha256-oldZipHash=";
                  };
                }
                ''
                  FROM oven/bun:9.1.0@sha256:1111111111111111111111111111111111111111111111111111111111111111 AS bun
                  FROM oven/bun:9.1.0@sha256:1111111111111111111111111111111111111111111111111111111111111111 AS tools
                ''
            )
          )
        }

        assert_equal "$release" '{"error":"the Dockerfile has 2 oven/bun stages pinned by digest, not 1"}'
      '';
    }
    {
      title = "it findBunRelease counts no oven/bun stage in a Dockerfile without one, or with an unpinned one";
      script = ''
        release=${
          lib.escapeShellArg (
            builtins.toJSON (
              findBunRelease
                {
                  "9.1.0" = {
                    digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
                    hash = "sha256-oldZipHash=";
                  };
                }
                ''
                  FROM oven/bun:9.1.0 AS bun
                  FROM debian:trixie-slim@sha256:3333333333333333333333333333333333333333333333333333333333333333 AS runtime
                ''
            )
          )
        }

        assert_equal "$release" '{"error":"the Dockerfile has 0 oven/bun stages pinned by digest, not 1"}'
      '';
    }
    {
      title = "it collectCaseRejections lists nothing for titles that are valid and unique";
      script = ''
        rejections=${
          lib.escapeShellArg (
            builtins.toJSON (collectCaseRejections [
              {
                title = "it reads the url, 2 times: a/b.c-d";
                script = "true";
              }
              {
                title = "it reads the url again";
                script = "true";
              }
            ])
          )
        }

        assert_equal "$rejections" '[]'
      '';
    }
    {
      title = "it collectCaseRejections lists an invalid title before a title two cases share";
      script = ''
        rejections=${
          lib.escapeShellArg (
            builtins.toJSON (collectCaseRejections [
              {
                title = "it reads the url";
                script = "true";
              }
              {
                title = "reads the url";
                script = "true";
              }
              {
                title = "it reads the url";
                script = "true";
              }
            ])
          )
        }

        assert_equal "$rejections" '["renderCases: titles must be \"it \" and letters, digits, spaces or , . / : -: reads the url","renderCases: titles must be unique: it reads the url"]'
      '';
    }
    {
      title = "it collectCaseRejections lists a title with an underscore";
      script = ''
        rejections=${
          lib.escapeShellArg (
            builtins.toJSON (collectCaseRejections [
              {
                title = "it reads IMPD_HEALTH_URL";
                script = "true";
              }
            ])
          )
        }

        assert_equal "$rejections" '["renderCases: titles must be \"it \" and letters, digits, spaces or , . / : -: it reads IMPD_HEALTH_URL"]'
      '';
    }
    {
      title = "it collectCaseRejections lists a title that does not start with it";
      script = ''
        rejections=${
          lib.escapeShellArg (
            builtins.toJSON (collectCaseRejections [
              {
                title = "reads the url";
                script = "true";
              }
            ])
          )
        }

        assert_equal "$rejections" '["renderCases: titles must be \"it \" and letters, digits, spaces or , . / : -: reads the url"]'
      '';
    }
    {
      title = "it collectCaseRejections lists a title two cases share";
      script = ''
        rejections=${
          lib.escapeShellArg (
            builtins.toJSON (collectCaseRejections [
              {
                title = "it reads the url";
                script = "true";
              }
              {
                title = "it reads the url";
                script = "false";
              }
            ])
          )
        }

        assert_equal "$rejections" '["renderCases: titles must be unique: it reads the url"]'
      '';
    }
    {
      title = "it buildModuleSystem evaluates the given module with the given config";
      script =
        let
          system = buildModuleSystem (
            { config, lib, ... }:
            {
              options.fixture.greeting = lib.mkOption { type = lib.types.str; };
              config.environment.etc.fixture.text = "greeting: ${config.fixture.greeting}";
            }
          ) { fixture.greeting = "hello"; };
        in
        ''
          evaluated=${
            lib.escapeShellArg (
              builtins.toJSON {
                inherit (system.config.fixture) greeting;
                etc = system.config.environment.etc.fixture.text;
              }
            )
          }

          assert_equal "$evaluated" '{"etc":"greeting: hello","greeting":"hello"}'
        '';
    }
    {
      title = "it buildModuleSystem adds no failing assertion of its own";
      script = ''
        failed=${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions (buildModuleSystem { } { })))}

        assert_equal "$failed" '[]'
      '';
    }
    {
      title = "it start-stub-server starts the stand-in it is given with its port read, and stops it when the case exits";
      script = ''
        mkdir home tmp
        source ${testLib}/wait-for.sh

        bash -c 'set -euo pipefail; source "$1"; start_stub_server "$2" /health 200 text/plain ok "$PWD/requests"; echo "$port" > port; curl -s "http://127.0.0.1:$port/health" > body' \
          _ ${./test-utils/start-stub-server.sh} ${./test-utils/run-stub-impd.py} > out 2> err

        # the stand-in's answer
        assert_equal "$(cat body)" ok
        # the stand-in's requests
        assert_equal "$(cat requests)" "GET /health"
        diff -u /dev/null out
        diff -u /dev/null err
        # curl exits 7 once nothing listens on the port
        wait_for 5 "the stand-in to stop" bash -c 'status=0; curl -s -o /dev/null "http://127.0.0.1:$1/health" || status=$?; [ "$status" = 7 ]' _ "$(cat port)"
      '';
    }
    {
      title = "it start-stub-server lets a case stop the stand-in first, with no error when the case exits";
      script = ''
        mkdir home tmp

        status=0
        bash -c 'set -euo pipefail; source "$1"; start_stub_server "$2" /health 200 text/plain ok "$PWD/requests"; kill "$stub_pid"; wait "$stub_pid" || true' \
          _ ${./test-utils/start-stub-server.sh} ${./test-utils/run-stub-impd.py} > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u /dev/null out
        diff -u /dev/null err
      '';
    }
    {
      title = "it run-stub-impd answers a GET of its path with the given status, content type and body, once it prints its port";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-impd.py} \
          /health 200 'application/json;charset=utf-8' '{"status":"ok","ready":true,"warnings":[]}' "$PWD/requests"

        curl -s -D headers -o body "http://127.0.0.1:$port/health"

        # the status line
        assert_equal "$(head -1 headers | tr -d '\r')" "HTTP/1.1 200 OK"
        # the content type
        assert_equal "$(grep -i '^content-type:' headers | tr -d '\r')" "Content-Type: application/json;charset=utf-8"
        # the body
        assert_equal "$(cat body)" '{"status":"ok","ready":true,"warnings":[]}'
        # the requests
        assert_equal "$(cat requests)" "GET /health"
      '';
    }
    {
      title = "it run-stub-impd records a request for another path and answers it with a failure";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-impd.py} \
          /health 200 'application/json;charset=utf-8' '{"status":"ok","ready":true,"warnings":[]}' "$PWD/requests"

        curl -s -D headers -o body "http://127.0.0.1:$port/ready"

        # the status line
        assert_equal "$(head -1 headers | tr -d '\r')" "HTTP/1.1 500 Internal Server Error"
        # the content type
        assert_equal "$(grep -i '^content-type:' headers | tr -d '\r')" "Content-Type: text/plain"
        # the body
        assert_equal "$(cat body)" "unexpected request: GET /ready"
        # the requests
        assert_equal "$(cat requests)" "GET /ready"
      '';
    }
    {
      title = "it run-stub-impd records a request with another method and answers it with a failure";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-impd.py} \
          /health 200 'application/json;charset=utf-8' '{"status":"ok","ready":true,"warnings":[]}' "$PWD/requests"

        curl -s -X POST -D headers -o body "http://127.0.0.1:$port/health"

        # the status line
        assert_equal "$(head -1 headers | tr -d '\r')" "HTTP/1.1 500 Internal Server Error"
        # the content type
        assert_equal "$(grep -i '^content-type:' headers | tr -d '\r')" "Content-Type: text/plain"
        # the body
        assert_equal "$(cat body)" "unexpected request: POST /health"
        # the requests
        assert_equal "$(cat requests)" "POST /health"
      '';
    }
    {
      title = "it run-stub-impd records a HEAD request and answers it with the headers of a failure and no body";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-impd.py} \
          /health 200 'application/json;charset=utf-8' '{"status":"ok","ready":true,"warnings":[]}' "$PWD/requests"

        # a raw request, so the check sees every byte the stand-in sends before it closes
        exec 4<>"/dev/tcp/127.0.0.1/$port"
        printf 'HEAD /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&4
        cat <&4 > response

        # Date is the time of the answer
        tr -d '\r' < response | sed 's/^Date: .* GMT$/Date: DATE/' > actual
        # Content-Length is the length of "unexpected request: HEAD /health", the body a GET would get
        cat > expected <<'EOF'
        HTTP/1.1 500 Internal Server Error
        Server: BaseHTTP/0.6 Python/${pkgs.python3.version}
        Date: DATE
        Content-Type: text/plain
        Content-Length: 32

        EOF
        diff -u expected actual
        assert_equal "$(cat requests)" "HEAD /health"
      '';
    }
    {
      title = "it run-stub-model-api answers a POST of its path with its JSON body, once it prints its port";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} \
          /v1/messages '{"type":"message","usage":{"input_tokens":12,"output_tokens":3}}' "$PWD/requests"

        curl -s -D headers -o body -X POST -H 'content-type: application/json' \
          -d '{"model":"model-small","max_tokens":3}' "http://127.0.0.1:$port/v1/messages"

        # the status line
        assert_equal "$(head -1 headers | tr -d '\r')" "HTTP/1.1 200 OK"
        # the content type
        assert_equal "$(grep -i '^content-type:' headers | tr -d '\r')" "Content-Type: application/json"
        # the body
        assert_equal "$(cat body)" '{"type":"message","usage":{"input_tokens":12,"output_tokens":3}}'
        # the requests
        assert_equal "$(cat requests)" "POST /v1/messages"
      '';
    }
    {
      title = "it run-stub-model-api reads a chunked request body and answers the request";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} \
          /v1/messages '{"type":"message","usage":{"input_tokens":12,"output_tokens":3}}' "$PWD/requests"

        # a raw request, so the body goes as two chunks with no Content-Length, as a streamed one does
        exec 4<>"/dev/tcp/127.0.0.1/$port"
        printf 'POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\n{"a":\r\n2\r\n1}\r\n0\r\n\r\n' >&4
        cat <&4 > response

        # the status line
        assert_equal "$(head -1 response | tr -d '\r')" "HTTP/1.1 200 OK"
        # the body
        assert_equal "$(tail -1 response)" '{"type":"message","usage":{"input_tokens":12,"output_tokens":3}}'
        # the requests
        assert_equal "$(cat requests)" "POST /v1/messages"
      '';
    }
    {
      title = "it run-stub-model-api records a request for another path and answers it with a failure";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} \
          /v1/messages '{"type":"message","usage":{"input_tokens":12,"output_tokens":3}}' "$PWD/requests"

        curl -s -D headers -o body -X POST -d '{}' "http://127.0.0.1:$port/v1/messages/batches"

        # the status line
        assert_equal "$(head -1 headers | tr -d '\r')" "HTTP/1.1 500 Internal Server Error"
        # the content type
        assert_equal "$(grep -i '^content-type:' headers | tr -d '\r')" "Content-Type: text/plain"
        # the body
        assert_equal "$(cat body)" "unexpected request: POST /v1/messages/batches"
        # the requests
        assert_equal "$(cat requests)" "POST /v1/messages/batches"
      '';
    }
    {
      title = "it run-stub-model-api records a request with another method and answers it with a failure";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-model-api.py} \
          /v1/messages '{"type":"message","usage":{"input_tokens":12,"output_tokens":3}}' "$PWD/requests"

        curl -s -D headers -o body "http://127.0.0.1:$port/v1/messages"

        # the status line
        assert_equal "$(head -1 headers | tr -d '\r')" "HTTP/1.1 500 Internal Server Error"
        # the content type
        assert_equal "$(grep -i '^content-type:' headers | tr -d '\r')" "Content-Type: text/plain"
        # the body
        assert_equal "$(cat body)" "unexpected request: GET /v1/messages"
        # the requests
        assert_equal "$(cat requests)" "GET /v1/messages"
      '';
    }
    {
      title = "it run-stub-impd holds to the pinned imp: its /health handler and its empty warnings, the default 404 of Elysia, Elysia 2.0.0-rc.3 and a Bun at the hashes of this check";
      script = ''
        handlers=$(grep -cxF "    .get('/health', () => ({" ${imp}/packages/daemon/src/surface/create-app.ts || true)
        grep -xF -A4 "    .get('/health', () => ({" ${imp}/packages/daemon/src/surface/create-app.ts > handler || true
        # with no reboot reason and no storage warnings, the warnings are the empty list the
        # stand-in's bodies hold
        grep -xF -A7 'function buildHealthWarnings(' ${imp}/packages/daemon/src/surface/create-app.ts > warnings || true
        # an Elysia onError hook would replace the default 404; create-app.ts's onError is oRPC's
        error_hooks=$(grep -cF '.onError(' ${imp}/packages/daemon/src/surface/create-app.ts || true)
        elysia=$(jq -r '.workspaces.catalog.elysia' ${imp}/package.json)
        grep -oE '"(elysia|deuri|exact-mirror|memoirist|typebox)": \["[^"]+".*"sha512-[^"]+"\]' \
          ${imp}/bun.lock | sed -E 's/^"([^"]+)": \["([^"]+)".*"(sha512-[^"]+)"\]$/\2 \3/' | sort > locked

        assert_equal "$handlers" 1
        diff -u - handler <<'EOF'
            .get('/health', () => ({
              status: 'ok',
              ready: deps.isReady(),
              warnings: buildHealthWarnings(deps.imps.readRebootReason(), deps.storage.readWarnings()),
            }))
        EOF
        diff -u - warnings <<'EOF'
        function buildHealthWarnings(
          rebootReason: string | null,
          storageWarnings: readonly string[],
        ): string[] {
          const reboot = rebootReason === null ? [] : [`host needs a reboot: ''${rebootReason}`];

          return [...reboot, ...storageWarnings];
        }
        EOF
        assert_equal "$error_hooks" 0
        assert_equal "$elysia" 2.0.0-rc.3
        # host/Dockerfile's Bun release
        assert_equal ${lib.escapeShellArg (impBunRelease.error or "")} ""
        cat > expected <<'EOF'
        deuri@3.0.1 sha512-IUgdopWhjToYbgpYDe3ZCBdzILexypCTCEakqDGQyKSlayxWL7yonY/zeJL9ICIjwVmAm3cpiAyT64rBn34gGg==
        elysia@2.0.0-rc.3 sha512-7W4qXQ6TBWGctaVwdYDhLFRKiXwROidVwdYEwlRLR5NaWLc17Mrj8CZOsFlD7xR+GzG/LrmvYjh/FC8vqkJvWw==
        exact-mirror@1.2.7 sha512-HhEYVm/y8qbEFnErtr0K7Jsuy0GzRlblZVyeaMoZBSKBDpNuELwzsWtzXQjezFVPka6ZqFaD6+EW3TW+x59vrw==
        memoirist@1.2.4 sha512-4ZQz65pzZQl1fQEy0EPplIo+rzn0c1vzrqhrdnswr2IKYoPje58p2hZCCeiDD3iB0Bh6OVIaScirDIw8S5qHaQ==
        typebox@1.4.6 sha512-Yh8Mi4hzD7gqcuv9ZIk6HK1KVJKubTlfxaNxkrYK35HCvxoCjCuWVr8cBjQ/ChfA7yliPteJEBWHGFVGWDuF5Q==
        EOF
        sort expected > expected-sorted
        diff -u expected-sorted locked
      '';
    }
  ]
  # with no release for the pinned imp's Bun, the case above fails with the message that names it
  ++ lib.optional (impBunRelease ? hash) (
    let
      # the Bun the pinned imp runs (host/Dockerfile's oven/bun stage), from its release
      pinnedBun = pkgs.stdenv.mkDerivation {
        pname = "bun";
        inherit (impBunRelease) version;
        src = pkgs.fetchurl {
          url = "https://github.com/oven-sh/bun/releases/download/bun-v${impBunRelease.version}/bun-linux-x64.zip";
          inherit (impBunRelease) hash;
        };
        nativeBuildInputs = [
          pkgs.unzip
          pkgs.autoPatchelfHook
        ];
        installPhase = "install -Dm755 bun $out/bin/bun";
        # stripping breaks the bun binary
        dontStrip = true;
      };

      # Elysia and its runtime dependencies at the versions and hashes of the pinned imp's bun.lock,
      # with an app that serves imp's /health handler and nothing else
      pinnedElysiaApp = pkgs.runCommand "pinned-elysia-app" { } ''
        unpack() {
          mkdir -p "$out/node_modules/$1"
          tar -xzf "$2" -C "$out/node_modules/$1" --strip-components=1
        }
        unpack elysia ${
          pkgs.fetchurl {
            url = "https://registry.npmjs.org/elysia/-/elysia-2.0.0-rc.3.tgz";
            hash = "sha512-7W4qXQ6TBWGctaVwdYDhLFRKiXwROidVwdYEwlRLR5NaWLc17Mrj8CZOsFlD7xR+GzG/LrmvYjh/FC8vqkJvWw==";
          }
        }
        unpack deuri ${
          pkgs.fetchurl {
            url = "https://registry.npmjs.org/deuri/-/deuri-3.0.1.tgz";
            hash = "sha512-IUgdopWhjToYbgpYDe3ZCBdzILexypCTCEakqDGQyKSlayxWL7yonY/zeJL9ICIjwVmAm3cpiAyT64rBn34gGg==";
          }
        }
        unpack exact-mirror ${
          pkgs.fetchurl {
            url = "https://registry.npmjs.org/exact-mirror/-/exact-mirror-1.2.7.tgz";
            hash = "sha512-HhEYVm/y8qbEFnErtr0K7Jsuy0GzRlblZVyeaMoZBSKBDpNuELwzsWtzXQjezFVPka6ZqFaD6+EW3TW+x59vrw==";
          }
        }
        unpack memoirist ${
          pkgs.fetchurl {
            url = "https://registry.npmjs.org/memoirist/-/memoirist-1.2.4.tgz";
            hash = "sha512-4ZQz65pzZQl1fQEy0EPplIo+rzn0c1vzrqhrdnswr2IKYoPje58p2hZCCeiDD3iB0Bh6OVIaScirDIw8S5qHaQ==";
          }
        }
        unpack typebox ${
          pkgs.fetchurl {
            url = "https://registry.npmjs.org/typebox/-/typebox-1.4.4.tgz";
            hash = "sha512-ctPyL8BZibv6HYU6cE3ldDtfCTh7nXM7WPuL3KQVyRRhMnZEzU3o2yLVywxEEFmKEx+8EdeqG1/uTNzazRbxLA==";
          }
        }
        cat > $out/app.ts <<'EOF'
        import { Elysia } from 'elysia';

        // packages/daemon/src/surface/create-app.ts's /health handler, with impd ready, no reboot
        // reason and no storage warnings
        const app = new Elysia()
          .get('/health', () => ({ status: 'ok', ready: true, warnings: [] }))
          .listen({ hostname: '127.0.0.1', port: 0 });

        console.log(app.server?.port);
        EOF
      '';
    in
    {
      title = "it run-stub-impd answers /health and an unknown route as the Elysia 2.0.0-rc.3 of imp on Bun ${impBunRelease.version} does";
      script = ''
        mkdir home tmp
        mkfifo real.fifo stub-health.fifo stub-missing.fifo
        exec 3<>real.fifo 4<>stub-health.fifo 5<>stub-missing.fifo
        real_pid=
        health_pid=
        missing_pid=
        trap '[ -n "$real_pid" ] && kill "$real_pid" || true; [ -n "$health_pid" ] && kill "$health_pid" || true; [ -n "$missing_pid" ] && kill "$missing_pid" || true' EXIT
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" ${pinnedBun}/bin/bun ${pinnedElysiaApp}/app.ts >&3 &
        real_pid=$!
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" python3 ${./test-utils/run-stub-impd.py} \
          /health 200 'application/json;charset=utf-8' '{"status":"ok","ready":true,"warnings":[]}' "$PWD/health.requests" >&4 &
        health_pid=$!
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" python3 ${./test-utils/run-stub-impd.py} \
          /missing 404 application/problem+json '{"type":"not-found","code":"not-found","status":404,"title":"Not Found"}' "$PWD/missing.requests" >&5 &
        missing_pid=$!
        read -r -t 30 -u 3 real_port
        read -r -t 5 -u 4 health_port
        read -r -t 5 -u 5 missing_port

        curl -s -D real-health.headers -o real-health.body "http://127.0.0.1:$real_port/health"
        curl -s -D real-missing.headers -o real-missing.body "http://127.0.0.1:$real_port/missing"
        curl -s -D stub-health.headers -o stub-health.body "http://127.0.0.1:$health_port/health"
        curl -s -D stub-missing.headers -o stub-missing.body "http://127.0.0.1:$missing_port/missing"

        # imp's /health status line
        assert_equal "$(head -1 real-health.headers | tr -d '\r')" "HTTP/1.1 200 OK"
        # the stand-in's /health status line
        assert_equal "$(head -1 stub-health.headers | tr -d '\r')" "HTTP/1.1 200 OK"
        # the /health content type
        assert_equal "$(grep -i '^content-type:' stub-health.headers | cut -d: -f2- | tr -d '\r')" "$(grep -i '^content-type:' real-health.headers | cut -d: -f2- | tr -d '\r')"
        diff -u real-health.body stub-health.body
        # imp's unknown route's status line
        assert_equal "$(head -1 real-missing.headers | tr -d '\r')" "HTTP/1.1 404 Not Found"
        # the stand-in's unknown route's status line
        assert_equal "$(head -1 stub-missing.headers | tr -d '\r')" "HTTP/1.1 404 Not Found"
        # the unknown route's content type
        assert_equal "$(grep -i '^content-type:' stub-missing.headers | cut -d: -f2- | tr -d '\r')" "$(grep -i '^content-type:' real-missing.headers | cut -d: -f2- | tr -d '\r')"
        diff -u real-missing.body stub-missing.body
        # the /health stand-in's requests
        assert_equal "$(cat health.requests)" "GET /health"
        # the unknown route stand-in's requests
        assert_equal "$(cat missing.requests)" "GET /missing"
      '';
    }
  )
  ++ [
    {
      title = "it run-stub-hung-impd takes a connection and never answers it, and buildStubCurl answers the call of the probe as curl then does";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-hung-impd.py}

        # one real wait serves both units: curl's own deadline is the only end it has
        real_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          curl -s --max-time 1 -o real.body -w '%{http_code} %{num_connects}' "http://127.0.0.1:$port/health" > real.out 2> real.err || real_status=$?
        stub_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CURL_LOG="$PWD/curl.log" \
          ${stubCurl} -s -o stub.body -w '%{http_code}' --max-time 1 "http://127.0.0.1:$port/health" > stub.out 2> stub.err || stub_status=$?

        assert_equal "$real_status" 28
        # curl's status code and connections
        assert_equal "$(cat real.out)" "000 1"
        # curl's body
        assert [ ! -e real.body ]
        assert [ ! -L real.body ]
        assert_equal "$stub_status" "$real_status"
        # the probe asks for the status code alone, the first of the two curl printed
        # the stand-in's status code
        assert_equal "$(cat stub.out)" "$(cut -d' ' -f1 real.out)"
        diff -u real.err stub.err
        # the stand-in's body
        assert [ ! -e stub.body ]
        assert [ ! -L stub.body ]
      '';
    }
    {
      title = "it run-stub-mcp-upstream records the method, target, host and authorization of each request, and answers it as text";
      script = ''
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-mcp-upstream.py} 0 "$PWD/requests" "$PWD/release"

        authorization='Authorization: Bearer example-token'
        curl -s -D headers -o body -X POST -H 'Host: mcp.example.test' -H "$authorization" \
          --data '{}' --path-as-is "http://127.0.0.1:$port/oauth2/../oauth2/token?client=a"

        # the status line
        assert_equal "$(head -1 headers | tr -d '\r')" "HTTP/1.1 200 OK"
        # the content type
        assert_equal "$(grep -i '^content-type:' headers | cut -d: -f2- | tr -d '\r')" " text/plain"
        # the body
        assert_equal "$(cat body)" "POST /oauth2/../oauth2/token?client=a"
        diff -u - requests <<'EOF'
        {"method": "POST", "path": "/oauth2/../oauth2/token?client=a", "host": "mcp.example.test", "authorization": "Bearer example-token"}
        EOF
      '';
    }
    {
      title = "it run-stub-mcp-upstream holds a GET of /mcp open after its first event until the release file exists";
      script = ''
        source ${testLib}/wait-for.sh
        mkdir home tmp
        start_stub_server ${./test-utils/run-stub-mcp-upstream.py} 0 "$PWD/requests" "$PWD/release"

        curl -s -N -D headers -o stream "http://127.0.0.1:$port/mcp" &
        curl_pid=$!
        wait_for 5 "the first event" grep -qx 'data: first' stream
        held=$(cat stream)
        kill -0 "$curl_pid"
        touch release
        wait "$curl_pid"

        # the stream before the release
        assert_equal "$(printf '%s' "$held" | sed '/^$/d')" "data: first"
        # the content type
        assert_equal "$(grep -i '^content-type:' headers | cut -d: -f2- | tr -d '\r')" " text/event-stream"
        diff -u - stream <<'EOF'
        data: first

        data: second

        EOF
        # the requests
        assert_equal "$(cat requests)" "{\"method\": \"GET\", \"path\": \"/mcp\", \"host\": \"127.0.0.1:$port\", \"authorization\": null}"
      '';
    }
    (
      let
        stubImage = import ./test-utils/build-stub-imp-host-image.nix { inherit pkgs; } "0.28.0";
      in
      {
        title = "it buildStubImpHostImage pins the image by its tag and the manifest digest of the layout, and names it by that digest alone";
        script = ''
          digest=$(jq -r '.manifests[0].digest' ${stubImage.layout}/index.json)

          # the reference
          assert_equal ${lib.escapeShellArg stubImage.ref} "ghcr.io/zgeoff/imp-host:0.28.0@$digest"
          # the reference by digest
          assert_equal ${lib.escapeShellArg stubImage.digestRef} "ghcr.io/zgeoff/imp-host@$digest"
          # the layout's manifests
          assert_equal "$(jq '.manifests | length' ${stubImage.layout}/index.json)" 1
          # the layout's tag
          assert_equal "$(jq -r '.manifests[0].annotations."org.opencontainers.image.ref.name"' ${stubImage.layout}/index.json)" 0.28.0
        '';
      }
    )
    (
      let
        stubImage = import ./test-utils/build-stub-imp-host-image.nix { inherit pkgs; } "0.28.0";
      in
      {
        title = "it buildStubImpHostImage saves the layout image, its command and layers, as an archive tagged with the image name and tag";
        script = ''
          tar -xOf ${stubImage.archive} manifest.json > archive-manifest
          blobs=${stubImage.layout}/blobs/sha256
          manifest=$blobs/$(jq -r '.manifests[0].digest | ltrimstr("sha256:")' ${stubImage.layout}/index.json)

          # the archive's tags
          assert_equal "$(jq -c '.[0].RepoTags' archive-manifest)" '["ghcr.io/zgeoff/imp-host:0.28.0"]'
          # the archive's images
          assert_equal "$(jq 'length' archive-manifest)" 1
          # the same command and layers; skopeo drops the archive config's empty Env and its
          # preferLocalBuild, which nothing reads
          tar -xOf ${stubImage.archive} "$(jq -r '.[0].Config' archive-manifest)" \
            | jq -S '{cmd: .config.Cmd, layers: .rootfs.diff_ids}' > archive-config
          jq -S '{cmd: .config.Cmd, layers: .rootfs.diff_ids}' \
            "$blobs/$(jq -r '.config.digest | ltrimstr("sha256:")' "$manifest")" > layout-config
          diff -u layout-config archive-config
        '';
      }
    )
    (
      let
        stubImage = import ./test-utils/build-stub-imp-host-image.nix { inherit pkgs; } "0.28.0";
      in
      {
        title = "it buildStubImpHostImage sleeps as imp-host, and its impz info prints the version";
        script = ''
          blobs=${stubImage.layout}/blobs/sha256
          manifest=$blobs/$(jq -r '.manifests[0].digest | ltrimstr("sha256:")' ${stubImage.layout}/index.json)
          layers=$(jq -r '.layers[].digest | ltrimstr("sha256:")' "$manifest")
          layer=$blobs/$layers
          config=$blobs/$(jq -r '.config.digest | ltrimstr("sha256:")' "$manifest")

          cmd=$(jq -c '.config.Cmd' "$config")
          tar -tvf "$layer" > listing
          sleep_target=$(sed -n 's|^l.* \./bin/sleep -> ||p' listing)
          # busybox's own bin/sleep is a link to the busybox binary beside it
          busybox_path=''${sleep_target%/sleep}/busybox
          busybox=$(grep -cE "^-r-xr-xr-x .* ''${busybox_path#/}\$" listing || true)

          # the image's layers
          assert_equal "$(printf '%s\n' "$layers" | wc -l)" 1
          assert_equal "$cmd" '["sleep","infinity"]'
          assert_equal "$sleep_target" "${pkgs.busybox}/bin/sleep"
          assert_equal "$busybox" 1

          impz=$(sed -n 's|^l.* \./usr/local/bin/impz -> /||p' listing)
          tar -xOf "$layer" "$impz" > impz-script
          tmp_mode=$(grep -E ' \./tmp/?$' listing | cut -c1-10)
          info_status=0
          sh impz-script info > info.out 2> info.err || info_status=$?
          other_status=0
          sh impz-script ls > other.out 2> other.err || other_status=$?

          assert_equal "$info_status" 0
          # impz info's output
          assert_equal "$(cat info.out)" 'version     0.28.0'
          diff -u /dev/null info.err
          assert_equal "$other_status" 97
          diff -u /dev/null other.out
          # another impz command's error
          assert_equal "$(cat other.err)" 'unexpected: impz ls'
          assert_equal "$tmp_mode" drwxrwxrwt
        '';
      }
    )
    {
      title = "it buildStubImpHostImage holds to the pinned imp: the module pulls the image by its reference, and runs imp-host with podman run from the own command of the image";
      script = ''
        pulls=$(grep -cxF '          ''${podman} image exists "$ref" || ''${podman} pull -q "$ref"' \
          ${imp}/deploy/nixos/config.nix || true)
        starts=$(grep -cxF '        ExecStart = "''${podman} run ''${lib.escapeShellArgs runArgs}";' \
          ${imp}/deploy/nixos/config.nix || true)
        runs=$(grep -cxF '  runArgs = privileges ++ probedArgs ++ sharedArgs ++ secretArgs ++ dnsArgs ++ [ cfg.image ];' \
          ${imp}/deploy/nixos/config.nix || true)

        assert_equal "$pulls" 1
        assert_equal "$starts" 1
        assert_equal "$runs" 1
      '';
    }
    {
      title = "it buildStubImpHostImage holds to the pinned impz info: the version line first, each label padded to 12 characters";
      script = ''
        info=${imp}/packages/cli/src/commands/info-command.ts
        first=$(grep -A1 -F 'const lines = [' "$info" | tail -n1 | tr -d ' ')
        # impz prints each line through console.log, from 2.5 on behind its io.print
        pads=$(grep -cE '(console\.log|io\.print)\(`\$\{label\.padEnd\(12\)\}\$\{value\}`\);' "$info" || true)

        assert_equal "$first" "['version',info.version],"
        assert_equal "$pads" 1
      '';
    }
    {
      title = "it buildStubSqlite3 holds the directory of the staged file, then answers as sqlite3";
      script = ''
        mkdir home tmp db
        sqlite3 db/imp.sqlite.restore 'CREATE TABLE t (v TEXT);'

        # the stand-in starts the holder and writes its PID file as it runs
        trap '[ -f holder.pid ] && kill "$(cat holder.pid)" || true' EXIT
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" HOLDER_PID_FILE=$PWD/holder.pid \
          ${stubSqlite3} "file:$PWD/db/imp.sqlite.restore?mode=ro&immutable=1" 'PRAGMA integrity_check;' > out 2> err
        holder=$(cat holder.pid)

        # sqlite3's answer
        assert_equal "$(cat out)" ok
        diff -u /dev/null err
        # the holder's working directory
        assert_equal "$(readlink /proc/$holder/cwd)" "$PWD/db"
      '';
    }
    {
      title = "it buildStubSqlite3 is sqlite3 alone for any other file";
      script = ''
        mkdir home tmp
        sqlite3 copy.sqlite 'CREATE TABLE t (v TEXT);'

        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" HOLDER_PID_FILE=$PWD/holder.pid \
          ${stubSqlite3} copy.sqlite 'PRAGMA integrity_check;' > out 2> err

        # sqlite3's answer
        assert_equal "$(cat out)" ok
        diff -u /dev/null err
        # a holder's PID file
        assert [ ! -e holder.pid ]
        assert [ ! -L holder.pid ]
      '';
    }
    {
      title = "it buildStubIntegritySqlite3 answers an integrity check with the real report on a damaged index, and exit 0";
      script = ''
        mkdir home tmp
        sqlite3 copy.sqlite 'CREATE TABLE t (v TEXT);'
        status=0

        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          ${stubIntegritySqlite3} copy.sqlite 'PRAGMA integrity_check;' > out 2> err || status=$?

        assert_equal "$status" 0
        printf '%s\n' 'wrong # of entries in index sqlite_autoindex_imps_1' \
          'row 1 missing from index sqlite_autoindex_imps_1' 'row 2 missing from index sqlite_autoindex_imps_1' \
          'row 3 missing from index sqlite_autoindex_imps_1' > expected
        diff -u expected out
        diff -u /dev/null err
      '';
    }
    {
      title = "it buildStubIntegritySqlite3 is sqlite3 alone for any other statement";
      script = ''
        mkdir home tmp
        sqlite3 copy.sqlite 'CREATE TABLE t (v TEXT);' "INSERT INTO t VALUES ('x');"

        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          ${stubIntegritySqlite3} copy.sqlite 'SELECT v FROM t;' > out 2> err

        assert_equal "$(cat out)" x
        diff -u /dev/null err
      '';
    }
    {
      title = "it buildStubIntegritySqlite3 holds to copy-impd-db-host: it checks the copy through SQLITE3";
      script = ''
        sqlite=$(grep -cxF 'sqlite="''${SQLITE3:-sqlite3}"' \
          ${../packages/impd-db-tools/copy-impd-db-host.sh} || true)
        checked=$(grep -cxF 'integrity=$("$sqlite" "$dir/imp.sqlite" "PRAGMA integrity_check;")' \
          ${../packages/impd-db-tools/copy-impd-db-host.sh} || true)

        assert_equal "$sqlite" 1
        assert_equal "$checked" 1
      '';
    }
    {
      title = "it buildStubSqlite3 and buildStubBlockingSqlite3 hold to restore-impd-db: it checks the staged file through SQLITE3";
      script = ''
        staged=$(grep -cxF 'staged="$db/imp.sqlite.restore"' ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        checked=$(grep -cF '[ "$("$sqlite" "file:$staged?mode=ro&immutable=1" '"'"'PRAGMA integrity_check;'"'"')" = ok ]' \
          ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        sqlite=$(grep -cxF 'sqlite="''${SQLITE3:-sqlite3}"' ${../packages/impd-db-tools/restore-impd-db.sh} || true)

        assert_equal "$staged" 1
        assert_equal "$checked" 1
        assert_equal "$sqlite" 1
      '';
    }
    {
      title = "it buildStubBlockingSqlite3 blocks on the check of the staged file, under the PID it writes, and answers nothing";
      script = ''
        mkdir home tmp db
        sqlite3 db/imp.sqlite.restore 'CREATE TABLE t (v TEXT);'
        source ${testLib}/wait-for.sh

        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" HOLDER_PID_FILE=$PWD/holder.pid \
          ${stubBlockingSqlite3} "file:$PWD/db/imp.sqlite.restore?mode=ro&immutable=1" 'PRAGMA integrity_check;' > out 2> err &
        stub_pid=$!
        trap 'kill -KILL "$stub_pid" || true' EXIT
        printf '%s\0' ${pkgs.coreutils}/bin/sleep infinity > expected-command
        # it writes the PID file just before it becomes sleep
        wait_for 30 "the stand-in to block" cmp -s expected-command /proc/$stub_pid/cmdline
        cp /proc/$stub_pid/cmdline command
        kill -KILL "$stub_pid"
        status=0
        wait "$stub_pid" || status=$?

        # the blocked process
        assert_equal "$(cat holder.pid)" "$stub_pid"
        diff -u expected-command command
        assert_equal "$status" 137
        diff -u /dev/null out
        diff -u /dev/null err
        # the partial PID file
        assert [ ! -e holder.pid.partial ]
        assert [ ! -L holder.pid.partial ]
      '';
    }
    {
      title = "it buildStubBlockingSqlite3 is sqlite3 alone for any other file";
      script = ''
        mkdir home tmp
        sqlite3 copy.sqlite 'CREATE TABLE t (v TEXT);'

        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" HOLDER_PID_FILE=$PWD/holder.pid \
          ${stubBlockingSqlite3} copy.sqlite 'PRAGMA integrity_check;' > out 2> err

        # sqlite3's answer
        assert_equal "$(cat out)" ok
        diff -u /dev/null err
        # a holder's PID file
        assert [ ! -e holder.pid ]
        assert [ ! -L holder.pid ]
      '';
    }
    {
      title = "it buildStubBlockingSqlite3 refuses to run without the file that names the blocked process";
      script = ''
        mkdir home tmp
        sqlite3 copy.sqlite 'CREATE TABLE t (v TEXT);'

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" ${stubBlockingSqlite3} copy.sqlite 'PRAGMA integrity_check;' \
          > out 2> err || status=$?

        assert_equal "$status" 2
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "sqlite3-blocking-on-staged-check: set HOLDER_PID_FILE to the file that names the blocked process"
      '';
    }
    {
      title = "it buildStubSystemctl fails the state read of its unit, with the message and status of systemctl";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" FAIL_SHOW_UNIT=imp-host \
          ${stubSystemctl} show -p ActiveState --value imp-host > out 2> err || status=$?

        assert_equal "$status" 1
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "Failed to get properties: Connection timed out"
      '';
    }
    {
      title = "it buildStubSystemctl passes the state read of another unit to systemctl unchanged";
      script = ''
        mkdir home tmp

        real_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          ${pkgs.systemd}/bin/systemctl show -p ActiveState --value imp-host-image > real.out 2> real.err || real_status=$?
        stub_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" FAIL_SHOW_UNIT=imp-host \
          ${stubSystemctl} show -p ActiveState --value imp-host-image > stub.out 2> stub.err || stub_status=$?

        assert_equal "$stub_status" "$real_status"
        diff -u real.out stub.out
        diff -u real.err stub.err
      '';
    }
    {
      title = "it buildStubSystemctl passes another property read of its unit to systemctl unchanged";
      script = ''
        mkdir home tmp

        real_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          ${pkgs.systemd}/bin/systemctl show -p SubState --value imp-host > real.out 2> real.err || real_status=$?
        stub_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" FAIL_SHOW_UNIT=imp-host \
          ${stubSystemctl} show -p SubState --value imp-host > stub.out 2> stub.err || stub_status=$?

        assert_equal "$stub_status" "$real_status"
        diff -u real.out stub.out
        diff -u real.err stub.err
      '';
    }
    {
      title = "it buildStubSystemctl passes a call that succeeds to systemctl unchanged";
      script = ''
        mkdir home tmp

        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" ${pkgs.systemd}/bin/systemctl --version > real.out 2> real.err
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" FAIL_SHOW_UNIT=imp-host \
          ${stubSystemctl} --version > stub.out 2> stub.err

        diff -u real.out stub.out
        diff -u real.err stub.err
        assert_not_equal "$(cat stub.out)" ""
      '';
    }
    {
      title = "it buildStubSystemctl passes its arguments to systemctl as given";
      script = ''
        mkdir home tmp

        real_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          ${pkgs.systemd}/bin/systemctl --no-such-option 'two words' > real.out 2> real.err || real_status=$?
        stub_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" FAIL_SHOW_UNIT=imp-host \
          ${stubSystemctl} --no-such-option 'two words' > stub.out 2> stub.err || stub_status=$?

        assert_equal "$stub_status" "$real_status"
        diff -u real.out stub.out
        diff -u real.err stub.err
        # the error, which names the argument
        assert_equal "$(cat stub.err)" "${pkgs.systemd}/bin/systemctl: unrecognized option '--no-such-option'"
      '';
    }
    {
      title = "it buildStubSystemctl refuses to run without the unit whose state read fails";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" ${stubSystemctl} --version > out 2> err || status=$?

        assert_equal "$status" 2
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "systemctl-failing-one-state-read: set FAIL_SHOW_UNIT to the unit whose state read fails"
      '';
    }
    {
      title = "it buildStubSystemctl holds: systemctl prints its message, and the script reads each state through SYSTEMCTL";
      script = ''
        message=$(grep -laF 'Failed to get properties: %s' ${pkgs.systemd}/bin/systemctl ${pkgs.systemd}/lib/systemd/libsystemd-shared-*.so | wc -l)
        systemctl=$(grep -cxF 'systemctl="''${SYSTEMCTL:-systemctl}"' ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        reads=$(grep -cxF '  unit_state="$("$systemctl" show -p ActiveState --value "$unit")" || fail "cannot read $unit'"'"'s state"' \
          ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        units=$(grep -cxF 'units=(imp-host)' ${../packages/impd-db-tools/restore-impd-db.sh} || true)

        assert_equal "$message" 1
        assert_equal "$systemctl" 1
        assert_equal "$reads" 1
        assert_equal "$units" 1
      '';
    }
    {
      title = "it buildStubCmp finds a difference in its one comparison, even between equal files, as cmp -s reports one";
      script = ''
        mkdir -p home tmp copy run/db
        printf 'same\n' > copy/imp.sqlite
        printf 'same\n' > run/db/imp.sqlite.restore

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/r*/db/imp.sqlite.restore" \
          ${stubCmp} -s "$PWD/copy/imp.sqlite" "$PWD/run/db/imp.sqlite.restore" > out 2> err || status=$?

        assert_equal "$status" 1
        diff -u /dev/null out
        diff -u /dev/null err
      '';
    }
    {
      title = "it buildStubCmp passes a comparison whose second file does not match to cmp unchanged";
      script = ''
        mkdir -p home tmp copy run/db
        printf 'same\n' > copy/imp.sqlite
        printf 'same\n' > run/db/imp.sqlite

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/r*/db/imp.sqlite.restore" \
          ${stubCmp} -s "$PWD/copy/imp.sqlite" "$PWD/run/db/imp.sqlite" > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u /dev/null out
        diff -u /dev/null err
      '';
    }
    {
      title = "it buildStubCmp passes a comparison whose first file does not match to cmp unchanged";
      script = ''
        mkdir -p home tmp copy run/db saved
        printf 'same\n' > run/db/imp.sqlite.restore
        printf 'same\n' > saved/imp.sqlite.restore

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/*/imp.sqlite.restore" \
          ${stubCmp} -s "$PWD/saved/imp.sqlite.restore" "$PWD/run/db/imp.sqlite.restore" > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u /dev/null out
        diff -u /dev/null err
      '';
    }
    {
      title = "it buildStubCmp passes its one comparison without -s to cmp unchanged";
      script = ''
        mkdir -p home tmp copy run/db
        printf 'same\n' > copy/imp.sqlite
        printf 'same\n' > run/db/imp.sqlite.restore

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/r*/db/imp.sqlite.restore" \
          ${stubCmp} "$PWD/copy/imp.sqlite" "$PWD/run/db/imp.sqlite.restore" > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u /dev/null out
        diff -u /dev/null err
      '';
    }
    {
      title = "it buildStubCmp passes a comparison of files that differ to cmp, with its arguments as given";
      script = ''
        mkdir home tmp
        printf 'one\n' > 'first file'
        printf 'two\n' > second

        real_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          ${pkgs.diffutils}/bin/cmp 'first file' second > real.out 2> real.err || real_status=$?
        stub_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/*" \
          ${stubCmp} 'first file' second > stub.out 2> stub.err || stub_status=$?

        assert_equal "$real_status" 1
        assert_equal "$stub_status" 1
        diff -u real.out stub.out
        diff -u real.err stub.err
        # the difference, which names the files
        assert_equal "$(cat stub.out)" "first file second differ: char 1, line 1"
      '';
    }
    {
      title = "it buildStubCmp passes a comparison with a missing file to cmp unchanged";
      script = ''
        mkdir home tmp
        printf 'one\n' > present

        real_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          ${pkgs.diffutils}/bin/cmp -s present missing > real.out 2> real.err || real_status=$?
        stub_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/*" \
          ${stubCmp} -s present missing > stub.out 2> stub.err || stub_status=$?

        assert_equal "$real_status" 2
        assert_equal "$stub_status" 2
        diff -u real.out stub.out
        diff -u real.err stub.err
      '';
    }
    {
      title = "it buildStubCmp refuses to run without the comparison that fails";
      script = ''
        mkdir home tmp
        printf 'one\n' > first
        printf 'one\n' > second

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" FAIL_CMP_FIRST=$PWD/first \
          ${stubCmp} -s first second > out 2> err || status=$?

        assert_equal "$status" 2
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "cmp-failing-one-comparison: set FAIL_CMP_FIRST and FAIL_CMP_SECOND to the comparison that fails"
      '';
    }
    {
      title = "it buildStubCmp holds to restore-impd-db: it compares through CMP, the copy first in its two checks";
      script = ''
        cmp=$(grep -cxF 'cmp="''${CMP:-cmp}"' ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        mount=$(grep -cxF 'mnt="$(mktemp -d /run/impd-restore.XXXXXX)"' ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        db=$(grep -cxF 'db="$mnt/db"' ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        staged_file=$(grep -cxF 'staged="$db/imp.sqlite.restore"' ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        staged=$(grep -cxF '"$cmp" -s "$copy/imp.sqlite" "$staged" || fail "the staged file differs from the copy"' \
          ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        published=$(grep -cxF '"$cmp" -s "$copy/imp.sqlite" "$db/imp.sqlite" || fail "the published database differs from the copy"' \
          ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        saved=$(grep -cxF '    "$cmp" -s "$db/$file" "$saved/$file" || fail "the saved $file differs from the original"' \
          ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        calls=$(grep -cF '"$cmp"' ${../packages/impd-db-tools/restore-impd-db.sh} || true)

        assert_equal "$cmp" 1
        assert_equal "$mount" 1
        assert_equal "$db" 1
        assert_equal "$staged_file" 1
        assert_equal "$staged" 1
        assert_equal "$published" 1
        assert_equal "$saved" 1
        assert_equal "$calls" 3
      '';
    }
    {
      title = "it buildStubCurl records the call of the probe as one JSON line, and answers it as curl that timed out";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CURL_LOG="$PWD/curl.log" \
          ${stubCurl} -s -o body -w '%{http_code}' --max-time 5 http://127.0.0.1:7070/health > out 2> err || status=$?

        assert_equal "$status" 28
        # the status code it prints
        assert_equal "$(cat out)" 000
        diff -u /dev/null err
        # a body
        assert [ ! -e body ]
        assert [ ! -L body ]
        # the recorded call
        assert_equal "$(cat curl.log)" '["-s","-o","body","-w","%{http_code}","--max-time","5","http://127.0.0.1:7070/health"]'
      '';
    }
    {
      title = "it buildStubCurl records each call on a line of its own, with its arguments as given";
      script = ''
        mkdir home tmp

        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CURL_LOG="$PWD/curl.log" \
          ${stubCurl} -s -o 'a body' -w '%{http_code}' --max-time 5 'http://127.0.0.1:7070/health?q="x"' > /dev/null || true
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CURL_LOG="$PWD/curl.log" \
          ${stubCurl} -s -o body -w '%{http_code}' --max-time 0.5 http://127.0.0.1:9090/ready > /dev/null || true

        cat > expected <<'EOF'
        ["-s","-o","a body","-w","%{http_code}","--max-time","5","http://127.0.0.1:7070/health?q=\"x\""]
        ["-s","-o","body","-w","%{http_code}","--max-time","0.5","http://127.0.0.1:9090/ready"]
        EOF
        diff -u expected curl.log
      '';
    }
    {
      title = "it buildStubCurl records another call and fails it as unexpected";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CURL_LOG="$PWD/curl.log" \
          ${stubCurl} -s http://127.0.0.1:7070/health > out 2> err || status=$?

        assert_equal "$status" 97
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "unexpected: -s http://127.0.0.1:7070/health"
        # the recorded call
        assert_equal "$(cat curl.log)" '["-s","http://127.0.0.1:7070/health"]'
      '';
    }
    {
      title = "it buildStubCurl refuses to run without the file that records its calls";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          ${stubCurl} -s -o body -w '%{http_code}' --max-time 5 http://127.0.0.1:7070/health > out 2> err || status=$?

        assert_equal "$status" 2
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "curl-timing-out: set CURL_LOG to the file that records each call"
      '';
    }
    {
      title = "it buildStubCurl holds to nixos/modules/impd-local-health.sh: it makes its one call through CURL";
      script = ''
        curl=$(grep -cxF 'curl="''${CURL:-curl}"' ${../modules/impd-local-health.sh} || true)
        call=$(grep -cxF 'code=$("$curl" -s -o "$body" -w '"'"'%{http_code}'"'"' --max-time "''${IMPD_HEALTH_TIMEOUT_SECONDS:-5}" "$IMPD_HEALTH_URL" || true)' \
          ${../modules/impd-local-health.sh} || true)
        calls=$(grep -cF '"$curl"' ${../modules/impd-local-health.sh} || true)
        # a call of curl by name, outside a comment, would pass the stand-in by
        direct=$(grep -cE '^[^#]*(^|[ $(])curl ' ${../modules/impd-local-health.sh} || true)

        assert_equal "$curl" 1
        assert_equal "$call" 1
        assert_equal "$calls" 1
        assert_equal "$direct" 0
      '';
    }
    {
      title = "it buildStubSleep records a pause of one duration as one JSON line, and returns as sleep does";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" SLEEP_LOG="$PWD/sleep.log" \
          ${stubSleep} 1 > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u /dev/null out
        diff -u /dev/null err
        # the recorded call
        assert_equal "$(cat sleep.log)" '["1"]'
      '';
    }
    {
      title = "it buildStubSleep answers a pause as the real sleep does";
      script = ''
        mkdir home tmp

        real_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" sleep 0 > real.out 2> real.err || real_status=$?
        stub_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" SLEEP_LOG="$PWD/sleep.log" \
          ${stubSleep} 0 > stub.out 2> stub.err || stub_status=$?

        assert_equal "$real_status" 0
        assert_equal "$stub_status" "$real_status"
        diff -u real.out stub.out
        diff -u real.err stub.err
      '';
    }
    {
      title = "it buildStubSleep records each call on a line of its own";
      script = ''
        mkdir home tmp

        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" SLEEP_LOG="$PWD/sleep.log" ${stubSleep} 1
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" SLEEP_LOG="$PWD/sleep.log" ${stubSleep} 0.5

        printf '%s\n' '["1"]' '["0.5"]' > expected
        diff -u expected sleep.log
      '';
    }
    {
      title = "it buildStubSleep records another call and fails it as unexpected";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" SLEEP_LOG="$PWD/sleep.log" \
          ${stubSleep} 1 'two words' > out 2> err || status=$?

        assert_equal "$status" 97
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "unexpected: 1 two words"
        # the recorded call
        assert_equal "$(cat sleep.log)" '["1","two words"]'
      '';
    }
    {
      title = "it buildStubSleep refuses to run without the file that records its calls";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" ${stubSleep} 1 > out 2> err || status=$?

        assert_equal "$status" 2
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "sleep-returning-at-once: set SLEEP_LOG to the file that records each call"
      '';
    }
    {
      title = "it buildStubSleep holds to restore-impd-db: its start loop pauses a second each try through the pause it is given";
      script = ''
        sleep_cmd=$(grep -cxF 'start_sleep="''${IMPD_START_SLEEP:-sleep}"' ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        loop=$(grep -cxF 'for _ in $(seq "$start_wait"); do' ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        pause=$(grep -cxF '  "$start_sleep" 1' ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        pauses=$(grep -cF '"$start_sleep"' ${../packages/impd-db-tools/restore-impd-db.sh} || true)
        # a pause by name, outside a comment, would pass the stand-in by
        direct=$(grep -cE '^[^#]*(^|[ ;&|(])sleep ' ${../packages/impd-db-tools/restore-impd-db.sh} || true)

        assert_equal "$sleep_cmd" 1
        assert_equal "$loop" 1
        assert_equal "$pause" 1
        assert_equal "$pauses" 1
        assert_equal "$direct" 0
      '';
    }
    {
      title = "it buildStubSleep holds to preview-image: its wait for impd pauses through the pause it is given";
      script = ''
        sleep_cmd=$(grep -cxF 'pause="''${SLEEP:-sleep}"' ${../modules/preview-image.sh} || true)
        pause=$(grep -cxF '  "$pause" 2' ${../modules/preview-image.sh} || true)
        pauses=$(grep -cF '"$pause"' ${../modules/preview-image.sh} || true)
        # a pause by name, outside a comment, would pass the stand-in by
        direct=$(grep -cE '^[^#]*(^|[ ;&|(])sleep ' ${../modules/preview-image.sh} || true)

        assert_equal "$sleep_cmd" 1
        assert_equal "$pause" 1
        assert_equal "$pauses" 1
        assert_equal "$direct" 0
      '';
    }
    {
      title = "it buildStorePathGaps lists the store path that a script names through a path value, and none it references";
      script =
        let
          script = pkgs.writeShellApplication {
            name = "names-a-stray-file";
            runtimeInputs = [ pkgs.jq ];
            runtimeEnv.STRAY_FILE = ./test-utils/run-stub-impd.py;
            text = ''
              jq . "$STRAY_FILE"
              ${pkgs.hello}/bin/hello
            '';
          };
          strayRoot = builtins.head (
            builtins.match "(${builtins.storeDir}/[^/]+)/.*" (toString ./test-utils/run-stub-impd.py)
          );
        in
        ''
          diff -u - ${buildStorePathGaps script} <<'EOF'
          ${strayRoot}
          EOF
        '';
    }
    {
      title = "it buildStorePathGaps lists nothing for a script that names only what it references";
      script =
        let
          script = pkgs.writeShellApplication {
            name = "names-its-own-file";
            runtimeEnv.OWN_FILE = "${./test-utils/run-stub-impd.py}";
            text = ''
              cat "$OWN_FILE"
            '';
          };
        in
        ''
          diff -u /dev/null ${buildStorePathGaps script}
        '';
    }
    {
      title = "it buildStubImpzHostImage impzlists the images with the token it finds under HOME, and records the call";
      script = ''
        mkdir -p home/.config/impz impd
        echo imp_fixture_root > impd/token
        echo imp_fixture_root > home/.config/impz/token
        echo '[{"name":"base","ref":"ghcr.io/example/base:1.0.0","pinned":false}]' > impd/images.json

        status=0
        env -i HOME="$PWD/home" IMPD_STATE="$PWD/impd" IMPD_TOKEN_FILE="$PWD/impd/token" \
          ${stubImpzHostImage.impz} image ls --json > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u - out <<'EOF'
        [
          {
            "name": "base",
            "ref": "ghcr.io/example/base:1.0.0",
            "pinned": false
          }
        ]
        EOF
        diff -u /dev/null err
        diff -u - impd/calls <<'EOF'
        ["image","ls","--json"]
        EOF
      '';
    }
    {
      title = "it buildStubImpzHostImage impzrefuses the call as a 401 when HOME is empty, so the token file path is relative and missing";
      script = ''
        mkdir impd work
        echo imp_fixture_root > impd/token
        echo '[]' > impd/images.json

        status=0
        (cd work && env -i HOME= IMPD_STATE="$PWD/../impd" IMPD_TOKEN_FILE="$PWD/../impd/token" \
          ${stubImpzHostImage.impz} image ls --json > ../out 2> ../err) || status=$?

        assert_equal "$status" 1
        diff -u /dev/null out
        diff -u - err <<'EOF'
        impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>
        EOF
      '';
    }
    {
      title = "it buildStubImpzHostImage impzrefuses the call as a 401 when the token it finds is not the impd one";
      script = ''
        mkdir -p home/.config/impz impd
        echo imp_fixture_root > impd/token
        echo imp_fixture_stale > home/.config/impz/token
        echo '[]' > impd/images.json

        status=0
        env -i HOME="$PWD/home" IMPD_STATE="$PWD/impd" IMPD_TOKEN_FILE="$PWD/impd/token" \
          ${stubImpzHostImage.impz} image ls --json > out 2> err || status=$?

        assert_equal "$status" 1
        diff -u - err <<'EOF'
        impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>
        EOF
      '';
    }
    {
      title = "it buildStubImpzHostImage impztakes the token from the environment over the token file, and adds then pins an image";
      script = ''
        mkdir impd
        echo imp_fixture_root > impd/token
        echo '[]' > impd/images.json

        status=0
        env -i HOME="$PWD/home" IMP_TOKEN=imp_fixture_root IMPD_STATE="$PWD/impd" IMPD_TOKEN_FILE="$PWD/impd/token" \
          ${stubImpzHostImage.impz} image add ghcr.io/example/base:1.0.0 --name pv-base --json > out 2> err || status=$?
        env -i HOME="$PWD/home" IMP_TOKEN=imp_fixture_root IMPD_STATE="$PWD/impd" IMPD_TOKEN_FILE="$PWD/impd/token" \
          ${stubImpzHostImage.impz} image pin pv-base >> out 2>> err || status=$?

        assert_equal "$status" 0
        # impd's images
        assert_equal "$(jq -c 'map([.name, .ref, .pinned])' impd/images.json)" '[["pv-base","ghcr.io/example/base:1.0.0",true]]'
        # the added image's name
        assert_equal "$(jq -c .name out)" '"pv-base"'
        diff -u /dev/null err
      '';
    }
    {
      title = "it buildStubImpzHostImage impzfails an unknown call with status 97";
      script = ''
        mkdir impd
        echo imp_fixture_root > impd/token
        echo '[]' > impd/images.json

        status=0
        env -i IMP_TOKEN=imp_fixture_root IMPD_STATE="$PWD/impd" IMPD_TOKEN_FILE="$PWD/impd/token" \
          ${stubImpzHostImage.impz} info > out 2> err || status=$?

        assert_equal "$status" 97
        # the error
        assert_equal "$(cat err)" 'unexpected: impz info'
      '';
    }
    {
      title = "it buildStubImpzHostImage curlanswers the impd /health as ready, and fails any other call with status 97";
      script = ''
        health_status=0
        ${stubImpzHostImage.curl} -sS --max-time 5 http://127.0.0.1:7070/health > health 2> health-err || health_status=$?
        other_status=0
        ${stubImpzHostImage.curl} -sS http://127.0.0.1:7070/v1/imps > other 2> other-err || other_status=$?

        assert_equal "$health_status" 0
        # the /health body
        assert_equal "$(cat health)" '{"status":"ok","ready":true,"warnings":[]}'
        assert_equal "$other_status" 97
        # the other call's error
        assert_equal "$(cat other-err)" 'unexpected: curl -sS http://127.0.0.1:7070/v1/imps'
      '';
    }
    {
      title = "it buildStubImpHostPodman prints the impd images for an image list, and records the call";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-1","name":"base","ref":"ghcr.io/example/base:1.0.0","digest":"imp-build-aa","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12}]' > impd/images.json

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz image ls --json > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u - out <<'EOF'
        [
          {
            "id": "img-1",
            "name": "base",
            "ref": "ghcr.io/example/base:1.0.0",
            "digest": "imp-build-aa",
            "source": "oci",
            "createdAt": "2026-02-03T04:05:06.000Z",
            "sizeBytes": 12
          }
        ]
        EOF
        diff -u /dev/null err
        # the recorded call
        assert_equal "$(cat impd/calls)" '["exec","imp-host","impz","image","ls","--json"]'
      '';
    }
    {
      title = "it buildStubImpHostPodman points a name at the added ref in place of the image of that name, and prints the image";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-1","name":"base","ref":"ghcr.io/example/base:1.0.0","digest":"imp-build-aa","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12},{"id":"img-2","name":"pv-base","ref":"ghcr.io/example/base:0.9.0","digest":"imp-build-bb","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12}]' > impd/images.json

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz image add ghcr.io/example/base:1.0.0 --name pv-base --json > out 2> err || status=$?

        assert_equal "$status" 0
        # the printed image
        assert_equal "$(jq -c '{name, ref, source}' out)" '{"name":"pv-base","ref":"ghcr.io/example/base:1.0.0","source":"oci"}'
        diff -u /dev/null err
        # impd's images
        assert_equal "$(jq -c 'map([.name, .ref])' impd/images.json)" '[["base","ghcr.io/example/base:1.0.0"],["pv-base","ghcr.io/example/base:1.0.0"]]'
      '';
    }
    {
      title = "it buildStubImpHostPodman keeps the pin of the image whose name an add points at a new ref";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-2","name":"pv-base","ref":"ghcr.io/example/base:0.9.0","digest":"imp-build-bb","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12,"pinned":true}]' > impd/images.json

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz image add ghcr.io/example/base:1.0.0 --name pv-base --json > out 2> err || status=$?

        assert_equal "$status" 0
        # the printed image
        assert_equal "$(jq -c '{name, ref, pinned}' out)" '{"name":"pv-base","ref":"ghcr.io/example/base:1.0.0","pinned":true}'
        diff -u /dev/null err
        # impd's images
        assert_equal "$(jq -c 'map([.name, .ref, .pinned])' impd/images.json)" '[["pv-base","ghcr.io/example/base:1.0.0",true]]'
      '';
    }
    {
      title = "it buildStubImpHostPodman pins the image of the name it is given, prints nothing, and leaves the other images alone";
      script = ''
        mkdir home tmp impd
        echo '[{"id":"img-1","name":"base","ref":"ghcr.io/example/base:1.0.0","digest":"imp-build-aa","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12,"pinned":false},{"id":"img-2","name":"pv-base","ref":"ghcr.io/example/base:0.9.0","digest":"imp-build-bb","source":"oci","createdAt":"2026-02-03T04:05:06.000Z","sizeBytes":12,"pinned":false}]' > impd/images.json

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz image pin pv-base > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u /dev/null out
        diff -u /dev/null err
        # impd's images
        assert_equal "$(jq -c 'map([.name, .pinned])' impd/images.json)" '[["base",false],["pv-base",true]]'
      '';
    }
    {
      title = "it buildStubImpHostPodman fails a pin of a name that holds no image, as impz fails a call";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz image pin pv-base > out 2> err || status=$?

        assert_equal "$status" 1
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "impz: NOT_FOUND: image pv-base not found"
        # impd's images
        assert_equal "$(cat impd/images.json)" '[]'
      '';
    }
    {
      title = "it buildStubImpHostPodman fails the calls its unreachable count names as podman fails a missing container, then answers";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 1 > impd/unreachable

        first_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz image ls --json > first.out 2> first.err || first_status=$?
        second_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz image ls --json > second.out 2> second.err || second_status=$?

        assert_equal "$first_status" 125
        diff -u /dev/null first.out
        # the first call's error
        assert_equal "$(cat first.err)" 'Error: no container with name or ID "imp-host" found: no such container'
        assert_equal "$second_status" 0
        # the second call's output
        assert_equal "$(cat second.out)" '[]'
        diff -u /dev/null second.err
      '';
    }
    {
      title = "it buildStubImpHostPodman fails the calls its unauthorized count names as impz fails a 401, once unreachable has none left, then answers";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 1 > impd/unreachable
        echo 1 > impd/unauthorized

        for call in first second third; do
          status=0
          env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
            ${stubImpHostPodman} exec imp-host impz image ls --json > "$call.out" 2> "$call.err" || status=$?
          echo "$status" > "$call.status"
        done

        # the first call's exit status
        assert_equal "$(cat first.status)" 125
        # the first call's error
        assert_equal "$(cat first.err)" 'Error: no container with name or ID "imp-host" found: no such container'
        # the second call's exit status
        assert_equal "$(cat second.status)" 1
        diff -u /dev/null second.out
        # the second call's error
        assert_equal "$(cat second.err)" 'impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>'
        # the third call's exit status
        assert_equal "$(cat third.status)" 0
        # the third call's output
        assert_equal "$(cat third.out)" '[]'
        diff -u /dev/null third.err
      '';
    }
    {
      title = "it buildStubImpHostPodman answers /health with ready false for the calls its starting count names, once unreachable has none left, then with ready true";
      script = ''
        mkdir home tmp impd
        echo 1 > impd/unreachable
        echo 1 > impd/starting

        for call in first second third; do
          status=0
          env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
            ${stubImpHostPodman} exec imp-host curl -sS --max-time 5 http://127.0.0.1:7070/health > "$call.out" 2> "$call.err" || status=$?
          echo "$status" > "$call.status"
        done

        # the first call's exit status
        assert_equal "$(cat first.status)" 125
        # the first call's error
        assert_equal "$(cat first.err)" 'Error: no container with name or ID "imp-host" found: no such container'
        # the second call's exit status
        assert_equal "$(cat second.status)" 0
        # the second call's output
        assert_equal "$(cat second.out)" '{"status":"ok","ready":false,"warnings":[]}'
        diff -u /dev/null second.err
        # the third call's exit status
        assert_equal "$(cat third.status)" 0
        # the third call's output
        assert_equal "$(cat third.out)" '{"status":"ok","ready":true,"warnings":[]}'
        diff -u /dev/null third.err
      '';
    }
    {
      title = "it buildStubImpHostPodman runs the script on stdin with dash, with each absolute path moved under container/, and prints its output";
      script = ''
        mkdir home tmp impd
        mkdir -p impd/container/var/lib/imp
        echo held > impd/container/var/lib/imp/marker

        status=0
        printf 'cat "$1"; echo "$2"; readlink -f /proc/$$/exe\n' |
          env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
            ${stubImpHostPodman} exec -i imp-host sh -s -- /var/lib/imp/marker relative > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u - out <<'EOF'
        held
        relative
        ${pkgs.dash}/bin/dash
        EOF
        diff -u /dev/null err
        # the recorded call
        assert_equal "$(cat impd/calls)" '["exec","-i","imp-host","sh","-s","--","/var/lib/imp/marker","relative"]'
      '';
    }
    {
      title = "it buildStubImpHostPodman fails the next script run with its script-error, with status 125 and no run, then runs the script";
      script = ''
        mkdir home tmp impd
        echo 'Error: no container with name or ID "imp-host" found: no such container' > impd/script-error

        for call in first second; do
          status=0
          echo 'echo ran' |
            env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
              ${stubImpHostPodman} exec -i imp-host sh -s -- > "$call.out" 2> "$call.err" || status=$?
          echo "$status" > "$call.status"
        done

        # the first run's exit status
        assert_equal "$(cat first.status)" 125
        diff -u /dev/null first.out
        # the first run's error
        assert_equal "$(cat first.err)" 'Error: no container with name or ID "imp-host" found: no such container'
        # the second run's exit status
        assert_equal "$(cat second.status)" 0
        # the second run's output
        assert_equal "$(cat second.out)" ran
        diff -u /dev/null second.err
      '';
    }
    {
      title = "it buildStubImpHostPodman prints the container ID of each inspect from container-ids, keeping the last";
      script = ''
        mkdir home tmp impd
        printf 'c0ffee01\nc0ffee02\n' > impd/container-ids

        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} container inspect --format '{{.Id}}' imp-host > first.out 2> first.err
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} container inspect --format '{{.Id}}' imp-host > second.out 2> second.err
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} container inspect --format '{{.Id}}' imp-host > third.out 2> third.err

        # the first inspect's output
        assert_equal "$(cat first.out)" c0ffee01
        # the second inspect's output
        assert_equal "$(cat second.out)" c0ffee02
        # the third inspect's output
        assert_equal "$(cat third.out)" c0ffee02
        diff -u /dev/null first.err
        diff -u /dev/null second.err
        diff -u /dev/null third.err
      '';
    }
    {
      title = "it buildStubImpHostPodman fails an inspect as podman fails a missing container when container-ids is missing";
      script = ''
        mkdir home tmp impd

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} container inspect --format '{{.Id}}' imp-host > out 2> err || status=$?

        assert_equal "$status" 125
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" 'Error: no such container "imp-host"'
      '';
    }
    {
      title = "it buildStubImpHostPodman fails the inspect that an empty line of container-ids names as podman fails a missing container";
      script = ''
        mkdir home tmp impd
        printf 'c0ffee01\n\n' > impd/container-ids

        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} container inspect --format '{{.Id}}' imp-host > first.out 2> first.err
        second_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} container inspect --format '{{.Id}}' imp-host > second.out 2> second.err || second_status=$?

        # the first inspect's output
        assert_equal "$(cat first.out)" c0ffee01
        diff -u /dev/null first.err
        assert_equal "$second_status" 125
        diff -u /dev/null second.out
        # the second inspect's error
        assert_equal "$(cat second.err)" 'Error: no such container "imp-host"'
      '';
    }
    {
      title = "it buildStubImpHostPodman fails the next add with its add-error as impz fails a call, and adds nothing";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        echo 'image ghcr.io/example/base:1.0.0: pull failed' > impd/add-error

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz image add ghcr.io/example/base:1.0.0 --name pv-base --json > out 2> err || status=$?

        assert_equal "$status" 1
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "impz: image ghcr.io/example/base:1.0.0: pull failed"
        # impd's images
        assert_equal "$(cat impd/images.json)" '[]'
      '';
    }
    {
      title = "it buildStubImpHostPodman records another call and fails it as unexpected";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz image rm 'two words' > out 2> err || status=$?

        assert_equal "$status" 97
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "unexpected: exec imp-host impz image rm two words"
        # the recorded call
        assert_equal "$(cat impd/calls)" '["exec","imp-host","impz","image","rm","two words"]'
      '';
    }
    {
      title = "it buildStubImpHostPodman prints the version line of impz info from its version file, and records the call";
      script = ''
        mkdir home tmp impd
        echo 4.5.6 > impd/version

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz info > out 2> err || status=$?

        assert_equal "$status" 0
        # the printed info
        assert_equal "$(cat out)" 'version     4.5.6'
        diff -u /dev/null err
        # the recorded call
        assert_equal "$(cat impd/calls)" '["exec","imp-host","impz","info"]'
      '';
    }
    {
      title = "it buildStubImpHostPodman fails impz info as unexpected without a version file";
      script = ''
        mkdir home tmp impd

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz info > out 2> err || status=$?

        assert_equal "$status" 97
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "unexpected: exec imp-host impz info"
      '';
    }
    {
      title = "it buildStubImpHostPodman prints a file of its container directory and its mode, and records the calls";
      script = ''
        mkdir -p home tmp impd/container/usr/local/bin
        printf '#!/bin/sh\necho stand-in\n' > impd/container/usr/local/bin/impz
        chmod 0750 impd/container/usr/local/bin/impz

        cat_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host cat /usr/local/bin/impz > cat.out 2> cat.err || cat_status=$?
        stat_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host stat -c %a /usr/local/bin/impz > stat.out 2> stat.err || stat_status=$?

        assert_equal "$cat_status" 0
        diff -u impd/container/usr/local/bin/impz cat.out
        diff -u /dev/null cat.err
        assert_equal "$stat_status" 0
        # the printed mode
        assert_equal "$(cat stat.out)" 750
        diff -u /dev/null stat.err
        diff -u - impd/calls <<'EOF'
        ["exec","imp-host","cat","/usr/local/bin/impz"]
        ["exec","imp-host","stat","-c","%a","/usr/local/bin/impz"]
        EOF
      '';
    }
    {
      title = "it buildStubImpHostPodman fails a cat and a stat of a path its container directory lacks, as GNU coreutils fails them";
      script = ''
        mkdir -p home tmp impd/container

        cat_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host cat /usr/local/bin/impz > cat.out 2> cat.err || cat_status=$?
        stat_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host stat -c %a /usr/local/bin/impz > stat.out 2> stat.err || stat_status=$?

        assert_equal "$cat_status" 1
        diff -u /dev/null cat.out
        # the cat error
        assert_equal "$(cat cat.err)" 'cat: /usr/local/bin/impz: No such file or directory'
        assert_equal "$stat_status" 1
        diff -u /dev/null stat.out
        # the stat error
        assert_equal "$(cat stat.err)" "stat: cannot statx '/usr/local/bin/impz': No such file or directory"
      '';
    }
    {
      title = "it buildStubImpHostPodman answers an exec that names a HOME as the same exec, and records it whole";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec -e HOME=/root imp-host impz image ls --json > out 2> err || status=$?

        assert_equal "$status" 0
        # the images
        assert_equal "$(cat out)" '[]'
        diff -u /dev/null err
        # the recorded call
        assert_equal "$(cat impd/calls)" '["exec","-e","HOME=/root","imp-host","impz","image","ls","--json"]'
      '';
    }
    {
      title = "it buildStubImpHostPodman refuses an impz exec that names no HOME as a 401 while its view is stale, and answers one that names it";
      script = ''
        mkdir home tmp impd
        echo '[]' > impd/images.json
        touch impd/stale-view

        bare_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec imp-host impz image ls --json > bare.out 2> bare.err || bare_status=$?
        named_status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" IMPD_STATE="$PWD/impd" \
          ${stubImpHostPodman} exec -e HOME=/root imp-host impz image ls --json > named.out 2> named.err || named_status=$?

        assert_equal "$bare_status" 1
        diff -u /dev/null bare.out
        # the error without HOME
        assert_equal "$(cat bare.err)" 'impz: unauthorized: set IMP_TOKEN to the token from <IMP_DATA_DIR>/token, or run impz login <url>'
        assert_equal "$named_status" 0
        # the images with HOME
        assert_equal "$(cat named.out)" '[]'
        diff -u /dev/null named.err
      '';
    }
    {
      title = "it buildStubAgentImageBun prints its stdout file for a build, and records the argv, directory, impd settings and impz of the build";
      script = ''
        mkdir home tmp build bin work
        printf '#!/bin/sh\n' > bin/impz
        chmod 0755 bin/impz
        echo 'agent-0123abc imp-build-aa check passed' > build/stdout

        root=$PWD
        status=0
        (cd work && env -i PATH="$root/bin:$PATH" HOME="$root/home" TMPDIR="$root/tmp" BUILD_STATE="$root/build" \
          IMP_URL=http://127.0.0.1:7070 IMP_TOKEN=imp_fixture_token \
          ${stubAgentImageBun} scripts/build-agent-image.ts 0123abcdef0123abcdef0123abcdef0123abcdef > "$root/out" 2> "$root/err") || status=$?

        assert_equal "$status" 0
        # the printed result
        assert_equal "$(cat out)" 'agent-0123abc imp-build-aa check passed'
        diff -u /dev/null err
        jq -S . > expected <<EOF
        {
          "argv": ["scripts/build-agent-image.ts", "0123abcdef0123abcdef0123abcdef0123abcdef"],
          "cwd": "$PWD/work",
          "impURL": "http://127.0.0.1:7070",
          "impToken": "imp_fixture_token",
          "impz": "$PWD/bin/impz"
        }
        EOF
        jq -S . build/calls > actual
        diff -u expected actual
      '';
    }
    {
      title = "it buildStubAgentImageBun exits with its status file, and records a null impz when PATH holds none";
      script = ''
        mkdir home tmp build
        echo 1 > build/status

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" BUILD_STATE="$PWD/build" \
          ${stubAgentImageBun} scripts/build-agent-image.ts 0123abc > out 2> err || status=$?

        assert_equal "$status" 1
        diff -u /dev/null out
        diff -u /dev/null err
        # the recorded call
        assert_equal "$(jq -c '{impURL, impToken, impz}' build/calls)" '{"impURL":null,"impToken":null,"impz":null}'
      '';
    }
    {
      title = "it buildStubAgentImageBun fails another call as unexpected, and records none";
      script = ''
        mkdir home tmp build

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" BUILD_STATE="$PWD/build" \
          ${stubAgentImageBun} scripts/build-agent-image.ts --keep 0123abc > out 2> err || status=$?

        assert_equal "$status" 97
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "unexpected: scripts/build-agent-image.ts --keep 0123abc"
        # the call log
        assert [ ! -e build/calls ]
        assert [ ! -L build/calls ]
      '';
    }
    {
      title = "it buildStubAgentImageBun refuses to run without the build state directory";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" ${stubAgentImageBun} scripts/build-agent-image.ts 0123abc > out 2> err || status=$?

        assert_equal "$status" 2
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "bun-answering-build-agent-image: set BUILD_STATE to the directory that holds the build's answer"
      '';
    }
    {
      title = "it buildStubImpHostPodman refuses to run without the impd state directory";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" ${stubImpHostPodman} exec imp-host impz image ls --json > out 2> err || status=$?

        assert_equal "$status" 2
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "podman-answering-impz: set IMPD_STATE to the directory that holds impd's images"
      '';
    }
    {
      title = "it buildStubImpHostPodman holds to preview-image: it reaches impd only through the podman it is given, with the five calls the stand-in answers";
      script = ''
        podman_cmd=$(grep -cxF 'podman="''${PODMAN:-podman}"' ${../modules/preview-image.sh} || true)
        health_url=$(grep -cxF 'health_url=http://127.0.0.1:7070/health' ${../modules/preview-image.sh} || true)
        health=$(grep -cxF '  health=$("$podman" exec imp-host curl -sS --max-time 5 "$health_url" 2> "$err") || return 1' ${../modules/preview-image.sh} || true)
        list=$(grep -cxF '  if [ -n "$ready" ] && images=$("$podman" exec -e HOME=/root imp-host impz image ls --json 2> "$err"); then' ${../modules/preview-image.sh} || true)
        facts=$(grep -cxF '    facts=$("$podman" exec -i imp-host sh -s -- /root/.config/impz/token /proc < "$token_facts" 2>&1) ||' ${../modules/preview-image.sh} || true)
        add=$(grep -cxF '  "$podman" exec -e HOME=/root imp-host impz image add "$ref" --name "$name" --json > /dev/null' ${../modules/preview-image.sh} || true)
        pin=$(grep -cxF '  "$podman" exec -e HOME=/root imp-host impz image pin "$name"' ${../modules/preview-image.sh} || true)
        calls=$(grep -cF '"$podman"' ${../modules/preview-image.sh} || true)
        # a podman call by name, outside a comment, would pass the stand-in by
        direct=$(grep -cE '^[^#]*(^|[ ;&|($])podman ' ${../modules/preview-image.sh} || true)

        assert_equal "$podman_cmd" 1
        assert_equal "$health_url" 1
        assert_equal "$health" 1
        assert_equal "$list" 1
        assert_equal "$facts" 1
        assert_equal "$add" 1
        assert_equal "$pin" 1
        assert_equal "$calls" 5
        assert_equal "$direct" 0
      '';
    }
    {
      title = "it buildStubOpRead prints the value of a reference with no newline added, as op read --no-newline does";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="${stubOpRead}/bin:$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          op read --no-newline op://vault/item/field > out 2> err || status=$?

        assert_equal "$status" 0
        diff -u /dev/null err
        printf '%s' 'a value with spaces' > expected
        diff -u expected out
      '';
    }
    {
      title = "it buildStubOpRead fails a reference it does not hold as op fails an unknown item";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="${stubOpRead}/bin:$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          op read --no-newline op://vault/item/missing > out 2> err || status=$?

        assert_equal "$status" 1
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "[ERROR] 2026/10/07 12:00:00 could not read secret op://vault/item/missing"
      '';
    }
    {
      title = "it buildStubOpRead fails a read without --no-newline as unexpected";
      script = ''
        mkdir home tmp

        status=0
        env -i PATH="${stubOpRead}/bin:$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" \
          op read op://vault/item/field > out 2> err || status=$?

        assert_equal "$status" 97
        diff -u /dev/null out
        # the error
        assert_equal "$(cat err)" "unexpected: read op://vault/item/field"
      '';
    }
  ];
  # renderCases' own tests, as a plain .bats file: the cases after them are rendered by it, so a
  # failing one stops the build before they run. Each runs bats on a file renderCases rendered.
  renderCasesTests = pkgs.writeText "render-cases.bats" ''
    bats_require_minimum_version 1.5.0

    setup() {
      bats_load_library bats-support
      bats_load_library bats-assert
      cd "$BATS_TEST_TMPDIR"
    }

    @test "it renderCases runs each case's script in a fresh directory of its own, under its title" {
      export log=$PWD

      bats --formatter tap ${
        pkgs.writeText "rendered-cases.bats" (renderCases [
          {
            title = "it writes where it runs";
            script = ''
              pwd > "$log/first-dir"
              ls -A > "$log/first-listing"
              cat > "$log/first-heredoc" <<'EOF'
              kept at the start of its line
              EOF
            '';
          }
          {
            title = "it writes where it runs, again";
            script = ''
              pwd > "$log/second-dir"
            '';
          }
        ])
      } > out 2>&1

      printf '%s\n' 1..2 'ok 1 it writes where it runs' 'ok 2 it writes where it runs, again' > expected
      diff -u expected out
      assert_equal "$(cat first-listing)" ""
      assert_equal "$(cat first-heredoc)" "kept at the start of its line"
      assert_not_equal "$(cat first-dir)" "$(cat second-dir)"
      assert_not_equal "$(cat first-dir)" "$log"
    }

    @test "it renderCases fails the run for a case whose assertion fails, and passes the cases around it" {
      run -1 bats --formatter tap ${
        pkgs.writeText "failing-cases.bats" (renderCases [
          {
            title = "it passes before";
            script = "true";
          }
          {
            title = "it asserts two values equal";
            script = "assert_equal one two";
          }
          {
            title = "it passes after";
            script = "true";
          }
        ])
      }

      assert_line "ok 1 it passes before"
      assert_line "not ok 2 it asserts two values equal"
      assert_line "ok 3 it passes after"
    }

    @test "it renderCases ends a case at its first failing command" {
      run -1 bats --formatter tap ${
        pkgs.writeText "errexit-cases.bats" (renderCases [
          {
            title = "it stops at the failing command";
            script = ''
              false
              touch ran-on
            '';
          }
        ])
      }

      assert_line "not ok 1 it stops at the failing command"
    }

    @test "it renderCases ends a case at the first unset variable and the first failing pipe stage" {
      run -1 bats --formatter tap ${
        pkgs.writeText "strict-cases.bats" (renderCases [
          {
            title = "it reads an unset variable";
            script = ''
              echo "$unset_variable"
            '';
          }
          {
            title = "it fails in a pipe";
            script = ''
              false | cat
            '';
          }
        ])
      }

      assert_line "not ok 1 it reads an unset variable"
      assert_line "not ok 2 it fails in a pipe"
    }

    @test "it renderCases lets a case set an EXIT trap and leave a background process running" {
      export log=$PWD

      # a background process that kept bats' output descriptor open would hold the run until it ends
      run timeout 20 bats --formatter tap ${
        pkgs.writeText "trap-cases.bats" (renderCases [
          {
            title = "it sets a trap and starts a process";
            script = ''
              trap 'echo trapped > "$log/trapped"' EXIT
              sleep 60 &
              echo $! > "$log/pid"
            '';
          }
        ])
      }
      kill "$(cat pid)" || true

      assert_success
      assert_line "ok 1 it sets a trap and starts a process"
      assert_equal "$(cat trapped)" trapped
    }

    @test "it renderCases sources each file of sources before the cases" {
      run bats --formatter tap ${
        pkgs.writeText "sourced-cases.bats" (
          (import ./test-utils/render-cases.nix {
            inherit lib;
            sources = [ (pkgs.writeText "greet.sh" "greet() { echo hello; }") ];
          })
            [
              {
                title = "it calls a sourced function";
                script = "assert_equal \"$(greet)\" hello";
              }
            ]
        )
      }

      assert_success
      assert_line "ok 1 it calls a sourced function"
    }

    @test "it renderCases defines assert_within, which takes a whole number from low to high" {
      run bats --formatter tap ${
        pkgs.writeText "within-cases.bats" (renderCases [
          {
            title = "it takes the low bound";
            script = "assert_within 5 5 9";
          }
          {
            title = "it takes the high bound";
            script = "assert_within 5 9 9";
          }
        ])
      }

      assert_success
    }

    @test "it renderCases defines assert_within, which fails a value that is below, above or no number" {
      run -1 bats --formatter tap ${
        pkgs.writeText "outside-cases.bats" (renderCases [
          {
            title = "it takes a value below";
            script = "assert_within 5 4 9";
          }
          {
            title = "it takes a value above";
            script = "assert_within 5 10 9";
          }
          {
            title = "it takes a word";
            script = "assert_within 5 six 9";
          }
          {
            title = "it takes an empty value";
            script = "assert_within 5 '' 9";
          }
        ])
      }

      assert_line "not ok 1 it takes a value below"
      assert_line "not ok 2 it takes a value above"
      assert_line "not ok 3 it takes a word"
      assert_line "not ok 4 it takes an empty value"
    }

    @test "it renderCases rejects a title with an underscore" {
      rendered=${
        lib.boolToString
          (builtins.tryEval (renderCases [
            {
              title = "it reads IMPD_HEALTH_URL";
              script = "true";
            }
          ])).success
      }

      assert_equal "$rendered" false
    }

    @test "it renderCases rejects a title that does not start with it" {
      rendered=${
        lib.boolToString
          (builtins.tryEval (renderCases [
            {
              title = "reads the url";
              script = "true";
            }
          ])).success
      }

      assert_equal "$rendered" false
    }

    @test "it renderCases rejects two cases with one title, where the second would replace the first" {
      rendered=${
        lib.boolToString
          (builtins.tryEval (renderCases [
            {
              title = "it reads the url";
              script = "true";
            }
            {
              title = "it reads the url";
              script = "false";
            }
          ])).success
      }

      assert_equal "$rendered" false
    }
  '';
in
pkgs.runCommand "test-utils-check"
  {
    nativeBuildInputs = [
      (pkgs.bats.withLibraries (p: [
        p.bats-support
        p.bats-assert
      ]))
      pkgs.curl
      pkgs.diffutils
      pkgs.gnutar
      pkgs.gzip
      pkgs.jq
      pkgs.python3
      pkgs.sqlite
    ];
  }
  ''
    set -euo pipefail
    # fixed, so the modes the tests assert do not depend on the builder's umask
    umask 022

    bats --timing --print-output-on-failure ${renderCasesTests}
    bats --timing --print-output-on-failure ${pkgs.writeText "test-utils-check.bats" (renderCases cases)}
    touch $out
  ''
