# Tests the checks' shared test utilities: case-helpers.sh and the stand-in impd,
# start-stub-impd.py. The checks that use them build this first, so a broken utility fails
# every check that relies on it instead of passing silently. It cannot use case-helpers.sh to
# test case-helpers.sh, so each test is plain bash that stops the build at its first failure.
{ pkgs, imp }:
pkgs.runCommand "test-utils-check"
  {
    nativeBuildInputs = [
      pkgs.curl
      pkgs.diffutils
      pkgs.jq
      pkgs.python3
    ];
  }
  ''
    set -euo pipefail
    helpers=${./case-helpers.sh}

    echo "it reports ok for a passing case, run in a directory of its own"
    got=$(
      source "$helpers"
      passing() { basename "$PWD" > ../seen-dir; }
      run_case "a passing case" passing-dir passing
      echo "failed $cases_failed"
    )
    [ "$got" = "$(printf 'ok - a passing case\nfailed 0')" ] || { echo "got: $got"; exit 1; }
    [ "$(cat seen-dir)" = passing-dir ] || { echo "ran in $(cat seen-dir)"; exit 1; }

    echo "it stops a case at its first failing command"
    got=$(
      source "$helpers"
      stops_early() {
        false
        touch reached
      }
      run_case "a case that fails first" early-dir stops_early
      echo "failed $cases_failed"
    )
    [ "$got" = "$(printf 'not ok - a case that fails first\nfailed 1')" ] || { echo "got: $got"; exit 1; }
    [ ! -e early-dir/reached ] || { echo "the case ran on past its failing command"; exit 1; }

    echo "it runs the cases after a failing one"
    got=$(
      source "$helpers"
      failing() { false; }
      passing() { true; }
      run_case "the failing case" failing-dir failing
      run_case "the next case" next-dir passing
      echo "failed $cases_failed"
    )
    [ "$got" = "$(printf 'not ok - the failing case\nok - the next case\nfailed 1')" ] || { echo "got: $got"; exit 1; }

    echo "it fails require_cases_passed after a failed case, saying how many"
    status=0
    got=$(
      source "$helpers"
      failing() { false; }
      run_case "one" one-dir failing >/dev/null
      run_case "two" two-dir failing >/dev/null
      require_cases_passed 2>&1
    ) || status=$?
    [ "$status" = 1 ] || { echo "exit $status"; exit 1; }
    [ "$got" = "2 case(s) failed" ] || { echo "got: $got"; exit 1; }

    echo "it passes require_cases_passed when every case passed"
    status=0
    got=$(
      source "$helpers"
      passing() { true; }
      run_case "one" pass-one-dir passing >/dev/null
      require_cases_passed 2>&1
    ) || status=$?
    [ "$status" = 0 ] || { echo "exit $status"; exit 1; }
    [ -z "$got" ] || { echo "got: $got"; exit 1; }

    echo "it passes assert_equals for equal strings"
    status=0
    got=$(source "$helpers"; assert_equals "a b" "a b" "the label" 2>&1) || status=$?
    [ "$status" = 0 ] && [ -z "$got" ] || { echo "exit $status: $got"; exit 1; }

    echo "it fails assert_equals for different strings, printing both"
    status=0
    got=$(source "$helpers"; assert_equals "a b" "a c" "the label" 2>&1) || status=$?
    [ "$status" = 1 ] || { echo "exit $status"; exit 1; }
    [ "$got" = 'the label: expected a\ b, got a\ c' ] || { echo "got: $got"; exit 1; }

    echo "it passes assert_between for both bounds and a value between"
    status=0
    got=$(
      source "$helpers"
      assert_between 1 1 9 low 2>&1
      assert_between 1 5 9 middle 2>&1
      assert_between 1 9 9 high 2>&1
    ) || status=$?
    [ "$status" = 0 ] && [ -z "$got" ] || { echo "exit $status: $got"; exit 1; }

    echo "it fails assert_between below the range"
    status=0
    got=$(source "$helpers"; assert_between 1 0 9 below 2>&1) || status=$?
    [ "$status" = 1 ] || { echo "exit $status"; exit 1; }
    [ "$got" = "below: expected 1..9, got 0" ] || { echo "got: $got"; exit 1; }

    echo "it fails assert_between above the range"
    status=0
    got=$(source "$helpers"; assert_between 1 10 9 above 2>&1) || status=$?
    [ "$status" = 1 ] || { echo "exit $status"; exit 1; }
    [ "$got" = "above: expected 1..9, got 10" ] || { echo "got: $got"; exit 1; }

    echo "it fails assert_between for a value that is not an integer"
    status=0
    got=$(source "$helpers"; assert_between 1 "" 9 empty 2>&1) || status=$?
    [ "$status" = 1 ] || { echo "exit $status"; exit 1; }
    [ "$got" = "empty: expected 1..9, got $(printf %q "")" ] || { echo "got: $got"; exit 1; }

    echo "it passes assert_files_equal for equal files"
    printf 'x\n' > same-a
    printf 'x\n' > same-b
    status=0
    got=$(source "$helpers"; assert_files_equal same-a same-b 2>&1) || status=$?
    [ "$status" = 0 ] && [ -z "$got" ] || { echo "exit $status: $got"; exit 1; }

    echo "it fails assert_files_equal for different files, printing the diff"
    printf 'x\n' > differ-a
    printf 'y\n' > differ-b
    status=0
    got=$(source "$helpers"; assert_files_equal differ-a differ-b 2>&1) || status=$?
    [ "$status" = 1 ] || { echo "exit $status"; exit 1; }
    [ "$(printf '%s\n' "$got" | tail -2)" = "$(printf -- '-x\n+y')" ] || { echo "got: $got"; exit 1; }

    echo "it answers with the given status, content type and body, once it prints its port"
    mkfifo json.fifo
    exec 3<>json.fifo
    python3 ${./start-stub-impd.py} 200 'application/json;charset=utf-8' '{"status":"ok","ready":true}' >&3 &
    stub_pid=$!
    read -r -t 5 -u 3 port
    curl -s -D json.headers -o json.body "http://127.0.0.1:$port/health"
    kill "$stub_pid"
    wait "$stub_pid" || true
    exec 3>&-
    [ "$(head -1 json.headers | tr -d '\r')" = "HTTP/1.0 200 OK" ] || { cat json.headers; exit 1; }
    [ "$(grep -i '^content-type:' json.headers | tr -d '\r')" = "Content-Type: application/json;charset=utf-8" ] ||
      { cat json.headers; exit 1; }
    [ "$(cat json.body)" = '{"status":"ok","ready":true}' ] || { cat json.body; exit 1; }

    echo "it sends no Content-Type when given an empty one"
    mkfifo bare.fifo
    exec 3<>bare.fifo
    python3 ${./start-stub-impd.py} 404 "" NOT_FOUND >&3 &
    stub_pid=$!
    read -r -t 5 -u 3 port
    curl -s -D bare.headers -o bare.body "http://127.0.0.1:$port/missing"
    kill "$stub_pid"
    wait "$stub_pid" || true
    exec 3>&-
    [ "$(head -1 bare.headers | tr -d '\r')" = "HTTP/1.0 404 Not Found" ] || { cat bare.headers; exit 1; }
    ! grep -qi '^content-type:' bare.headers || { cat bare.headers; exit 1; }
    [ "$(cat bare.body)" = NOT_FOUND ] || { cat bare.body; exit 1; }

    echo "it answers as the pinned imp's /health handler does, on that imp's Elysia version"
    handlers=$(grep -cxF "    .get('/health', () => ({ status: 'ok', ready: deps.isReady() }))" \
      ${imp}/packages/daemon/src/build-app.ts || true)
    [ "$handlers" = 1 ] || { echo "imp's build-app.ts has $handlers such /health handlers"; exit 1; }
    elysia=$(jq '.workspaces.catalog.elysia' ${imp}/package.json)
    [ "$elysia" = '"1.4.29"' ] || { echo "imp's Elysia version is $elysia"; exit 1; }

    touch $out
  ''
