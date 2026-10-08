# Tests the checks' shared test utilities: the shell helpers in scripts/test-lib that the checks
# source (run-cases.sh and the assert_* helpers, by their own suites), and the Nix helpers and
# stand-ins in nixos/checks/test-utils. The checks that use them build this first, so a broken
# utility fails every check that relies on it instead of passing silently. The shell suites run
# first; each later test is plain bash in a fresh directory of its own that may use the assert_*
# helpers, since their suites have passed by then. A failing test stops the build: the runner
# under test cannot run its own tests.
{ pkgs, imp }:
let
  lib = pkgs.lib;
  testLib = ../../scripts/test-lib;
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;
  stubImage = import ./test-utils/build-stub-imp-host-image.nix { inherit pkgs; } "0.28.0";
  stubSqlite3 = import ./test-utils/build-stub-sqlite3.nix { inherit pkgs; };
  stubSystemctl = import ./test-utils/build-stub-systemctl.nix { inherit pkgs; };
  stubCmp = import ./test-utils/build-stub-cmp.nix { inherit pkgs; };

  # the Bun the pinned imp runs (host/Dockerfile's oven/bun:1.4.2), from its release
  pinnedBun = pkgs.stdenv.mkDerivation {
    pname = "bun";
    version = "1.4.2";
    src = pkgs.fetchurl {
      url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-linux-x64.zip";
      hash = "sha256-NjaPrvdSeHXV/6UuU81IAhdB8qg+tiCKjdZAaNQiqRM=";
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
        url = "https://registry.npmjs.org/elysia/-/elysia-1.4.29.tgz";
        hash = "sha512-GwMRGGwSdjfPt+w3LA0fqTuYJtS8uVRJicvoar98/HrO5qdFKDc9CwjIb6Kja+v39lkY+58hr2JvdR9jQzlUuA==";
      }
    }
    unpack @sinclair/typebox ${
      pkgs.fetchurl {
        url = "https://registry.npmjs.org/@sinclair/typebox/-/typebox-0.34.52.tgz";
        hash = "sha512-XiMQh7qqVlxZzcVD+kkGMNGMzcTrDMLWI7S4x7z1MkCkbDPrekpZXEUK0eZqZFMuHQg2a2DZOcDIh9o5v3Gonw==";
      }
    }
    unpack cookie ${
      pkgs.fetchurl {
        url = "https://registry.npmjs.org/cookie/-/cookie-1.1.1.tgz";
        hash = "sha512-ei8Aos7ja0weRpFzJnEA9UHJ/7XQmqglbRwnf2ATjcB9Wq874VKH9kfjjirM6UhU2/E5fFYadylyhFldcqSidQ==";
      }
    }
    unpack exact-mirror ${
      pkgs.fetchurl {
        url = "https://registry.npmjs.org/exact-mirror/-/exact-mirror-0.2.7.tgz";
        hash = "sha512-+MeEmDcLA4o/vjK2zujgk+1VTxPR4hdp23qLqkWfStbECtAq9gmsvQa3LW6z/0GXZyHJobrCnmy1cdeE7BjsYg==";
      }
    }
    unpack fast-decode-uri-component ${
      pkgs.fetchurl {
        url = "https://registry.npmjs.org/fast-decode-uri-component/-/fast-decode-uri-component-1.0.1.tgz";
        hash = "sha512-WKgKWg5eUxvRZGwW8FvfbaH7AXSh2cL+3j5fMGzUMCxWBJ3dV3a7Wz8y2f/uQ0e3B6WmodD3oS54jTQ9HVTIIg==";
      }
    }
    unpack memoirist ${
      pkgs.fetchurl {
        url = "https://registry.npmjs.org/memoirist/-/memoirist-0.4.0.tgz";
        hash = "sha512-zxTgA0mSYELa66DimuNQDvyLq36AwDlTuVRbnQtB+VuTcKWm5Qc4z3WkSpgsFWHNhexqkIooqpv4hdcqrX5Nmg==";
      }
    }
    cat > $out/app.ts <<'EOF'
    import { Elysia } from 'elysia';

    // packages/daemon/src/build-app.ts's /health handler, with impd ready
    const app = new Elysia()
      .get('/health', () => ({ status: 'ok', ready: true }))
      .listen({ hostname: '127.0.0.1', port: 0 });

    console.log(app.server?.port);
    EOF
  '';
in
pkgs.runCommand "test-utils-check"
  {
    nativeBuildInputs = [
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

    bash ${testLib}/test-run-cases.sh
    bash ${testLib}/test-assert-equals.sh
    bash ${testLib}/test-assert-not-equals.sh
    bash ${testLib}/test-assert-files-equal.sh
    bash ${testLib}/test-assert-between.sh
    bash ${testLib}/test-assert-missing.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-not-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${testLib}/assert-missing.sh

    echo "#renderCases runs each case's script in a fresh directory of its own, under its title"
    (
      cd "$(mktemp -d)"
      log=$PWD

      (
        source ${testLib}/run-cases.sh
        source ${
          pkgs.writeText "rendered-cases.sh" (renderCases [
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
        }
        run_cases
      ) > out 2>&1

      printf '%s\n' 'ok it writes where it runs' 'ok it writes where it runs, again' '2 cases, 0 failed' > expected
      assert_files_equal expected out
      assert_equals "" "$(cat first-listing)" "the first case's directory, as it starts"
      assert_equals "kept at the start of its line" "$(cat first-heredoc)" "the first case's heredoc"
      assert_not_equals "$(cat first-dir)" "$(cat second-dir)" "the second case's directory"
      assert_not_equals "$log" "$(cat first-dir)" "the first case's directory"
    )

    echo "#renderCases rejects a title with an underscore, which run_cases would print as a space"
    (
      cd "$(mktemp -d)"

      rendered=${
        lib.boolToString
          (builtins.tryEval (renderCases [
            {
              title = "it reads IMPD_HEALTH_URL";
              script = "true";
            }
          ])).success
      }

      assert_equals false "$rendered" "whether it rendered"
    )

    echo "#renderCases rejects a title that does not start with it"
    (
      cd "$(mktemp -d)"

      rendered=${
        lib.boolToString
          (builtins.tryEval (renderCases [
            {
              title = "reads the url";
              script = "true";
            }
          ])).success
      }

      assert_equals false "$rendered" "whether it rendered"
    )

    echo "#renderCases rejects two cases with one title, where the second would replace the first"
    (
      cd "$(mktemp -d)"

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

      assert_equals false "$rendered" "whether it rendered"
    )

    echo "#collectFailedAssertions lists the messages of the failing assertions, in order"
    (
      cd "$(mktemp -d)"

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

      assert_equals '["first","second"]' "$failed" "the failed assertions"
    )

    echo "#collectFailedAssertions lists nothing when every assertion holds"
    (
      cd "$(mktemp -d)"

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

      assert_equals '[]' "$failed" "the failed assertions"
    )

    echo "#start-stub-impd answers with the given status, content type and body, once it prints its port"
    (
      cd "$(mktemp -d)"
      mkfifo port.fifo
      exec 3<>port.fifo
      python3 ${./test-utils/start-stub-impd.py} 200 'application/json;charset=utf-8' '{"status":"ok","ready":true}' >&3 &
      stub_pid=$!
      trap 'kill "$stub_pid"' EXIT
      read -r -t 5 -u 3 port

      curl -s -D headers -o body "http://127.0.0.1:$port/health"

      assert_equals "HTTP/1.1 200 OK" "$(head -1 headers | tr -d '\r')" "the status line"
      assert_equals "Content-Type: application/json;charset=utf-8" \
        "$(grep -i '^content-type:' headers | tr -d '\r')" "the content type"
      assert_equals '{"status":"ok","ready":true}' "$(cat body)" "the body"
    )

    echo "#start-stub-impd's premises hold in the pinned imp: its /health handler, Elysia's default 404, Elysia 1.4.29 and Bun 1.4.2 at this check's hashes"
    (
      cd "$(mktemp -d)"

      handlers=$(grep -cxF "    .get('/health', () => ({ status: 'ok', ready: deps.isReady() }))" \
        ${imp}/packages/daemon/src/build-app.ts || true)
      # an Elysia onError hook would replace the default 404; build-app.ts's onError is oRPC's
      error_hooks=$(grep -cF '.onError(' ${imp}/packages/daemon/src/build-app.ts || true)
      elysia=$(jq -r '.workspaces.catalog.elysia' ${imp}/package.json)
      bun=$(grep -c '^FROM oven/bun:1\.4\.2@' ${imp}/host/Dockerfile || true)
      grep -oE '"(elysia|@sinclair/typebox|cookie|exact-mirror|fast-decode-uri-component|memoirist)": \["[^"]+".*"sha512-[^"]+"\]' \
        ${imp}/bun.lock | sed -E 's/^"([^"]+)": \["([^"]+)".*"(sha512-[^"]+)"\]$/\2 \3/' | sort > locked

      assert_equals 1 "$handlers" "build-app.ts's /health handlers"
      assert_equals 0 "$error_hooks" "build-app.ts's Elysia onError hooks"
      assert_equals 1.4.29 "$elysia" "imp's Elysia version"
      assert_equals 1 "$bun" "host/Dockerfile's oven/bun:1.4.2 stages"
      cat > expected <<'EOF'
    @sinclair/typebox@0.34.52 sha512-XiMQh7qqVlxZzcVD+kkGMNGMzcTrDMLWI7S4x7z1MkCkbDPrekpZXEUK0eZqZFMuHQg2a2DZOcDIh9o5v3Gonw==
    cookie@1.1.1 sha512-ei8Aos7ja0weRpFzJnEA9UHJ/7XQmqglbRwnf2ATjcB9Wq874VKH9kfjjirM6UhU2/E5fFYadylyhFldcqSidQ==
    elysia@1.4.29 sha512-GwMRGGwSdjfPt+w3LA0fqTuYJtS8uVRJicvoar98/HrO5qdFKDc9CwjIb6Kja+v39lkY+58hr2JvdR9jQzlUuA==
    exact-mirror@0.2.7 sha512-+MeEmDcLA4o/vjK2zujgk+1VTxPR4hdp23qLqkWfStbECtAq9gmsvQa3LW6z/0GXZyHJobrCnmy1cdeE7BjsYg==
    fast-decode-uri-component@1.0.1 sha512-WKgKWg5eUxvRZGwW8FvfbaH7AXSh2cL+3j5fMGzUMCxWBJ3dV3a7Wz8y2f/uQ0e3B6WmodD3oS54jTQ9HVTIIg==
    memoirist@0.4.0 sha512-zxTgA0mSYELa66DimuNQDvyLq36AwDlTuVRbnQtB+VuTcKWm5Qc4z3WkSpgsFWHNhexqkIooqpv4hdcqrX5Nmg==
    EOF
      sort expected > expected-sorted
      assert_files_equal expected-sorted locked
    )

    echo "#start-stub-impd answers /health and an unknown route as imp's Elysia 1.4.29 on Bun 1.4.2 does"
    (
      cd "$(mktemp -d)"
      mkfifo real.fifo stub-health.fifo stub-missing.fifo
      exec 3<>real.fifo 4<>stub-health.fifo 5<>stub-missing.fifo
      HOME=$PWD ${pinnedBun}/bin/bun ${pinnedElysiaApp}/app.ts >&3 &
      real_pid=$!
      trap 'kill "$real_pid"' EXIT
      python3 ${./test-utils/start-stub-impd.py} 200 'application/json;charset=utf-8' '{"status":"ok","ready":true}' >&4 &
      health_pid=$!
      trap 'kill "$real_pid" "$health_pid"' EXIT
      python3 ${./test-utils/start-stub-impd.py} 404 'text/plain;charset=utf-8' NOT_FOUND >&5 &
      missing_pid=$!
      trap 'kill "$real_pid" "$health_pid" "$missing_pid"' EXIT
      read -r -t 30 -u 3 real_port
      read -r -t 5 -u 4 health_port
      read -r -t 5 -u 5 missing_port

      curl -s -D real-health.headers -o real-health.body "http://127.0.0.1:$real_port/health"
      curl -s -D real-missing.headers -o real-missing.body "http://127.0.0.1:$real_port/missing"
      curl -s -D stub-health.headers -o stub-health.body "http://127.0.0.1:$health_port/health"
      curl -s -D stub-missing.headers -o stub-missing.body "http://127.0.0.1:$missing_port/missing"

      assert_equals "HTTP/1.1 200 OK" "$(head -1 real-health.headers | tr -d '\r')" "imp's /health status line"
      assert_equals "HTTP/1.1 200 OK" "$(head -1 stub-health.headers | tr -d '\r')" "the stand-in's /health status line"
      assert_equals "$(grep -i '^content-type:' real-health.headers | cut -d: -f2- | tr -d '\r ')" \
        "$(grep -i '^content-type:' stub-health.headers | cut -d: -f2- | tr -d '\r ')" "the /health content type"
      assert_files_equal real-health.body stub-health.body
      assert_equals "HTTP/1.1 404 Not Found" "$(head -1 real-missing.headers | tr -d '\r')" "imp's unknown route's status line"
      assert_equals "HTTP/1.1 404 Not Found" "$(head -1 stub-missing.headers | tr -d '\r')" "the stand-in's unknown route's status line"
      assert_equals "$(grep -i '^content-type:' real-missing.headers | cut -d: -f2- | tr -d '\r ')" \
        "$(grep -i '^content-type:' stub-missing.headers | cut -d: -f2- | tr -d '\r ')" "the unknown route's content type"
      assert_files_equal real-missing.body stub-missing.body
    )

    echo "#start-stub-hung-impd takes a connection and never answers it"
    (
      cd "$(mktemp -d)"
      mkfifo port.fifo
      exec 3<>port.fifo
      python3 ${./test-utils/start-stub-hung-impd.py} >&3 &
      stub_pid=$!
      trap 'kill "$stub_pid"' EXIT
      read -r -t 5 -u 3 port

      status=0
      # curl's own deadline is the only end such a wait has
      curl -s --max-time 1 -o body -w '%{http_code} %{num_connects}' "http://127.0.0.1:$port/health" > got || status=$?

      assert_equals 28 "$status" "curl's exit status, a timeout"
      assert_equals "000 1" "$(cat got)" "curl's status code and connections"
      assert_missing body "a body"
    )

    echo "#buildStubImpHostImage pins the image by its tag and the layout's manifest digest"
    (
      cd "$(mktemp -d)"

      digest=$(jq -r '.manifests[0].digest' ${stubImage.layout}/index.json)

      assert_equals "ghcr.io/zgeoff/imp-host:0.28.0@$digest" ${lib.escapeShellArg stubImage.ref} "the reference"
      assert_equals 1 "$(jq '.manifests | length' ${stubImage.layout}/index.json)" "the layout's manifests"
      assert_equals 0.28.0 "$(jq -r '.manifests[0].annotations."org.opencontainers.image.ref.name"' ${stubImage.layout}/index.json)" \
        "the layout's tag"
    )

    echo "#buildStubImpHostImage sleeps as imp-host, and its imp-docker-proxy only opens the socket"
    (
      cd "$(mktemp -d)"
      blobs=${stubImage.layout}/blobs/sha256
      manifest=$blobs/$(jq -r '.manifests[0].digest | ltrimstr("sha256:")' ${stubImage.layout}/index.json)
      layers=$(jq -r '.layers[].digest | ltrimstr("sha256:")' "$manifest")
      layer=$blobs/$layers
      config=$blobs/$(jq -r '.config.digest | ltrimstr("sha256:")' "$manifest")

      cmd=$(jq -c '.config.Cmd' "$config")
      tar -tvf "$layer" > listing
      proxy=$(sed -n 's|^l.* \./usr/local/bin/imp-docker-proxy -> /||p' listing)
      tar -xOf "$layer" "$proxy" > proxy-script
      proxy_mode=$(grep -E " $proxy\$" listing | cut -c1-10)
      sleep_target=$(sed -n 's|^l.* \./bin/sleep -> ||p' listing)
      # busybox's own bin/sleep is a link to the busybox binary beside it
      busybox_path=''${sleep_target%/sleep}/busybox
      busybox=$(grep -cE "^-r-xr-xr-x .* ''${busybox_path#/}\$" listing || true)

      assert_equals 1 "$(printf '%s\n' "$layers" | wc -l)" "the image's layers"
      assert_equals '["sleep","infinity"]' "$cmd" "the image's command"
      printf '%s\n' '#!/bin/sh' 'exec ${pkgs.socat}/bin/socat UNIX-LISTEN:/run/imp-docker/docker.sock,fork EXEC:/bin/true' > expected
      assert_files_equal expected proxy-script
      assert_equals -r-xr-xr-x "$proxy_mode" "the proxy's mode"
      assert_equals "${pkgs.busybox}/bin/sleep" "$sleep_target" "the image's sleep"
      assert_equals 1 "$busybox" "the image's busybox binaries"
    )

    echo "#buildStubImpHostImage's premises hold in the pinned imp: the proxy's path and socket, and imp-host's own command"
    (
      cd "$(mktemp -d)"

      command=$(jq -c '.proxy.command' ${imp}/deploy/imp-host.args.json)
      waits=$(grep -cF '[ -S /run/imp-docker/docker.sock ] && exit 0' ${imp}/deploy/nixos/module.nix || true)
      runs=$(grep -cxF '  runArgs = privileges ++ probedArgs ++ sharedArgs ++ secretArgs ++ dnsArgs ++ [ cfg.image ];' \
        ${imp}/deploy/nixos/module.nix || true)

      assert_equals '["/usr/local/bin/imp-docker-proxy"]' "$command" "the proxy's command"
      assert_equals 1 "$waits" "the module's waits for the proxy's socket"
      assert_equals 1 "$runs" "the module's imp-host runs that end at the image, with no command"
    )

    echo "#buildStubSqlite3 holds the staged file's directory, then answers as sqlite3"
    (
      cd "$(mktemp -d)"
      mkdir db
      sqlite3 db/imp.sqlite.restore 'CREATE TABLE t (v TEXT);'

      HOLDER_PID_FILE=$PWD/holder.pid ${stubSqlite3} "file:$PWD/db/imp.sqlite.restore?mode=ro&immutable=1" \
        'PRAGMA integrity_check;' > out 2> err
      holder=$(cat holder.pid)
      trap 'kill "$holder"' EXIT

      assert_equals ok "$(cat out)" "sqlite3's answer"
      assert_files_equal /dev/null err
      assert_equals "$PWD/db" "$(readlink /proc/$holder/cwd)" "the holder's working directory"
    )

    echo "#buildStubSqlite3 is sqlite3 alone for any other file"
    (
      cd "$(mktemp -d)"
      sqlite3 copy.sqlite 'CREATE TABLE t (v TEXT);'

      HOLDER_PID_FILE=$PWD/holder.pid ${stubSqlite3} copy.sqlite 'PRAGMA integrity_check;' > out 2> err

      assert_equals ok "$(cat out)" "sqlite3's answer"
      assert_files_equal /dev/null err
      assert_missing holder.pid "a holder's PID file"
    )

    echo "#buildStubSqlite3's premises hold in scripts/restore-impd-db.sh: it checks the staged file through \$SQLITE3"
    (
      cd "$(mktemp -d)"

      staged=$(grep -cxF 'staged="$db/imp.sqlite.restore"' ${../../scripts/restore-impd-db.sh} || true)
      checked=$(grep -cF '[ "$("$sqlite" "file:$staged?mode=ro&immutable=1" '"'"'PRAGMA integrity_check;'"'"')" = ok ]' \
        ${../../scripts/restore-impd-db.sh} || true)
      sqlite=$(grep -cxF 'sqlite="''${SQLITE3:-sqlite3}"' ${../../scripts/restore-impd-db.sh} || true)

      assert_equals 1 "$staged" "the script's staged file"
      assert_equals 1 "$checked" "the script's checks of the staged file"
      assert_equals 1 "$sqlite" "the script's sqlite3"
    )

    echo "#buildStubSystemctl fails the state read of its unit, with systemctl's message and status"
    (
      cd "$(mktemp -d)"

      status=0
      FAIL_SHOW_UNIT=imp-docker-proxy ${stubSystemctl} show -p ActiveState --value imp-docker-proxy > out 2> err || status=$?

      assert_equals 1 "$status" "the exit status"
      assert_files_equal /dev/null out
      assert_equals "Failed to get properties: Connection timed out" "$(cat err)" "the error"
    )

    echo "#buildStubSystemctl passes the state read of another unit to systemctl unchanged"
    (
      cd "$(mktemp -d)"

      real_status=0
      ${pkgs.systemd}/bin/systemctl show -p ActiveState --value imp-host > real.out 2> real.err || real_status=$?
      stub_status=0
      FAIL_SHOW_UNIT=imp-docker-proxy ${stubSystemctl} show -p ActiveState --value imp-host > stub.out 2> stub.err ||
        stub_status=$?

      assert_equals "$real_status" "$stub_status" "the exit status"
      assert_files_equal real.out stub.out
      assert_files_equal real.err stub.err
    )

    echo "#buildStubSystemctl passes another property read of its unit to systemctl unchanged"
    (
      cd "$(mktemp -d)"

      real_status=0
      ${pkgs.systemd}/bin/systemctl show -p SubState --value imp-docker-proxy > real.out 2> real.err || real_status=$?
      stub_status=0
      FAIL_SHOW_UNIT=imp-docker-proxy ${stubSystemctl} show -p SubState --value imp-docker-proxy > stub.out 2> stub.err ||
        stub_status=$?

      assert_equals "$real_status" "$stub_status" "the exit status"
      assert_files_equal real.out stub.out
      assert_files_equal real.err stub.err
    )

    echo "#buildStubSystemctl passes a call that succeeds to systemctl unchanged"
    (
      cd "$(mktemp -d)"

      ${pkgs.systemd}/bin/systemctl --version > real.out 2> real.err
      FAIL_SHOW_UNIT=imp-docker-proxy ${stubSystemctl} --version > stub.out 2> stub.err

      assert_files_equal real.out stub.out
      assert_files_equal real.err stub.err
      assert_not_equals "" "$(cat stub.out)" "the version"
    )

    echo "#buildStubSystemctl passes its arguments to systemctl as given"
    (
      cd "$(mktemp -d)"

      real_status=0
      ${pkgs.systemd}/bin/systemctl --no-such-option 'two words' > real.out 2> real.err || real_status=$?
      stub_status=0
      FAIL_SHOW_UNIT=imp-docker-proxy ${stubSystemctl} --no-such-option 'two words' > stub.out 2> stub.err || stub_status=$?

      assert_equals "$real_status" "$stub_status" "the exit status"
      assert_files_equal real.out stub.out
      assert_files_equal real.err stub.err
      assert_equals "${pkgs.systemd}/bin/systemctl: unrecognized option '--no-such-option'" "$(cat stub.err)" \
        "the error, which names the argument"
    )

    echo "#buildStubSystemctl refuses to run without the unit whose state read fails"
    (
      cd "$(mktemp -d)"

      status=0
      ${stubSystemctl} --version > out 2> err || status=$?

      assert_equals 2 "$status" "the exit status"
      assert_files_equal /dev/null out
      assert_equals "systemctl-failing-one-state-read: set FAIL_SHOW_UNIT to the unit whose state read fails" "$(cat err)" \
        "the error"
    )

    echo "#buildStubSystemctl's premises hold: systemctl prints its message, and the script reads each state through \$SYSTEMCTL"
    (
      cd "$(mktemp -d)"

      message=$(grep -laF 'Failed to get properties: %s' ${pkgs.systemd}/bin/systemctl ${pkgs.systemd}/lib/systemd/libsystemd-shared-*.so | wc -l)
      systemctl=$(grep -cxF 'systemctl="''${SYSTEMCTL:-systemctl}"' ${../../scripts/restore-impd-db.sh} || true)
      reads=$(grep -cxF '  unit_state="$("$systemctl" show -p ActiveState --value "$unit")" || fail "cannot read $unit'"'"'s state"' \
        ${../../scripts/restore-impd-db.sh} || true)
      units=$(grep -cxF 'units=(imp-host imp-docker-proxy)' ${../../scripts/restore-impd-db.sh} || true)

      assert_not_equals 0 "$message" "systemd's files that hold the message"
      assert_equals 1 "$systemctl" "the script's systemctl"
      assert_equals 1 "$reads" "the script's state reads"
      assert_equals 1 "$units" "the script's units"
    )

    echo "#buildStubCmp finds a difference in its one comparison, even between equal files, as cmp -s reports one"
    (
      cd "$(mktemp -d)"
      mkdir -p copy run/db
      printf 'same\n' > copy/imp.sqlite
      printf 'same\n' > run/db/imp.sqlite.restore

      status=0
      FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/r*/db/imp.sqlite.restore" \
        ${stubCmp} -s "$PWD/copy/imp.sqlite" "$PWD/run/db/imp.sqlite.restore" > out 2> err || status=$?

      assert_equals 1 "$status" "the exit status"
      assert_files_equal /dev/null out
      assert_files_equal /dev/null err
    )

    echo "#buildStubCmp passes a comparison whose second file does not match to cmp unchanged"
    (
      cd "$(mktemp -d)"
      mkdir -p copy run/db
      printf 'same\n' > copy/imp.sqlite
      printf 'same\n' > run/db/imp.sqlite

      status=0
      FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/r*/db/imp.sqlite.restore" \
        ${stubCmp} -s "$PWD/copy/imp.sqlite" "$PWD/run/db/imp.sqlite" > out 2> err || status=$?

      assert_equals 0 "$status" "the exit status"
      assert_files_equal /dev/null out
      assert_files_equal /dev/null err
    )

    echo "#buildStubCmp passes a comparison whose first file does not match to cmp unchanged"
    (
      cd "$(mktemp -d)"
      mkdir -p copy run/db saved
      printf 'same\n' > run/db/imp.sqlite.restore
      printf 'same\n' > saved/imp.sqlite.restore

      status=0
      FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/*/imp.sqlite.restore" \
        ${stubCmp} -s "$PWD/saved/imp.sqlite.restore" "$PWD/run/db/imp.sqlite.restore" > out 2> err || status=$?

      assert_equals 0 "$status" "the exit status"
      assert_files_equal /dev/null out
      assert_files_equal /dev/null err
    )

    echo "#buildStubCmp passes its one comparison without -s to cmp unchanged"
    (
      cd "$(mktemp -d)"
      mkdir -p copy run/db
      printf 'same\n' > copy/imp.sqlite
      printf 'same\n' > run/db/imp.sqlite.restore

      status=0
      FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/r*/db/imp.sqlite.restore" \
        ${stubCmp} "$PWD/copy/imp.sqlite" "$PWD/run/db/imp.sqlite.restore" > out 2> err || status=$?

      assert_equals 0 "$status" "the exit status"
      assert_files_equal /dev/null out
      assert_files_equal /dev/null err
    )

    echo "#buildStubCmp passes a comparison of files that differ to cmp, with its arguments as given"
    (
      cd "$(mktemp -d)"
      printf 'one\n' > 'first file'
      printf 'two\n' > second

      real_status=0
      ${pkgs.diffutils}/bin/cmp 'first file' second > real.out 2> real.err || real_status=$?
      stub_status=0
      FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/*" ${stubCmp} 'first file' second > stub.out 2> stub.err ||
        stub_status=$?

      assert_equals 1 "$real_status" "cmp's exit status"
      assert_equals 1 "$stub_status" "the stand-in's exit status"
      assert_files_equal real.out stub.out
      assert_files_equal real.err stub.err
      assert_equals "first file second differ: char 1, line 1" "$(cat stub.out)" "the difference, which names the files"
    )

    echo "#buildStubCmp passes a comparison with a missing file to cmp unchanged"
    (
      cd "$(mktemp -d)"
      printf 'one\n' > present

      real_status=0
      ${pkgs.diffutils}/bin/cmp -s present missing > real.out 2> real.err || real_status=$?
      stub_status=0
      FAIL_CMP_FIRST=$PWD/copy/imp.sqlite FAIL_CMP_SECOND="$PWD/*" ${stubCmp} -s present missing > stub.out 2> stub.err ||
        stub_status=$?

      assert_equals 2 "$real_status" "cmp's exit status"
      assert_equals 2 "$stub_status" "the stand-in's exit status"
      assert_files_equal real.out stub.out
      assert_files_equal real.err stub.err
    )

    echo "#buildStubCmp refuses to run without the comparison that fails"
    (
      cd "$(mktemp -d)"
      printf 'one\n' > first
      printf 'one\n' > second

      status=0
      FAIL_CMP_FIRST=$PWD/first ${stubCmp} -s first second > out 2> err || status=$?

      assert_equals 2 "$status" "the exit status"
      assert_files_equal /dev/null out
      assert_equals "cmp-failing-one-comparison: set FAIL_CMP_FIRST and FAIL_CMP_SECOND to the comparison that fails" \
        "$(cat err)" "the error"
    )

    echo "#buildStubCmp's premises hold in scripts/restore-impd-db.sh: it compares through \$CMP, the copy first in its two checks"
    (
      cd "$(mktemp -d)"

      cmp=$(grep -cxF 'cmp="''${CMP:-cmp}"' ${../../scripts/restore-impd-db.sh} || true)
      mount=$(grep -cxF 'mnt="$(mktemp -d /run/impd-restore.XXXXXX)"' ${../../scripts/restore-impd-db.sh} || true)
      db=$(grep -cxF 'db="$mnt/db"' ${../../scripts/restore-impd-db.sh} || true)
      staged_file=$(grep -cxF 'staged="$db/imp.sqlite.restore"' ${../../scripts/restore-impd-db.sh} || true)
      staged=$(grep -cxF '"$cmp" -s "$copy/imp.sqlite" "$staged" || fail "the staged file differs from the copy"' \
        ${../../scripts/restore-impd-db.sh} || true)
      published=$(grep -cxF '"$cmp" -s "$copy/imp.sqlite" "$db/imp.sqlite" || fail "the published database differs from the copy"' \
        ${../../scripts/restore-impd-db.sh} || true)
      saved=$(grep -cxF '    "$cmp" -s "$db/$file" "$saved/$file" || fail "the saved $file differs from the original"' \
        ${../../scripts/restore-impd-db.sh} || true)
      calls=$(grep -cF '"$cmp"' ${../../scripts/restore-impd-db.sh} || true)

      assert_equals 1 "$cmp" "the script's cmp"
      assert_equals 1 "$mount" "the script's mount directory"
      assert_equals 1 "$db" "the script's database directory"
      assert_equals 1 "$staged_file" "the script's staged file"
      assert_equals 1 "$staged" "the script's checks of the staged file"
      assert_equals 1 "$published" "the script's checks of the published database"
      assert_equals 1 "$saved" "the script's checks of the saved files"
      assert_equals 3 "$calls" "the script's comparisons"
    )

    touch $out
  ''
