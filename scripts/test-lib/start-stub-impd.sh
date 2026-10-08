# shellcheck shell=bash
# start_stub_impd <dir>: starts a stand-in for impd's tokens.whoami on an ephemeral
# loopback port and returns once it listens. <dir>/port then holds the port and <dir>/pid
# the process to kill when the case ends.
#
# POST /rpc/tokens/whoami with the bearer that <dir>/good-token holds, read at each
# request, gets atc-cloud's identity (200, in imp's {"json": Identity} envelope); any other
# bearer, or any bearer while <dir>/good-token is missing, gets impd's 401
# {"error":"unauthorized"}. Every other
# request, whatever its method, fails closed, as the shell stand-ins' exit 97 does: it
# appends "<method> <path>" to <dir>/unexpected and answers 500 with a body naming the
# stand-in, which no caller reads as impd's answer.
#
# Checked on 2026-10-08 against imp's source at the revision the host runs, imp 0.40.0 at
# 2679ab06fe075530ae1a5010f99cec00009dd4bb (nixos/flake.lock): IdentitySchema in
# packages/api/src/token-schema.ts, the 401 body in packages/daemon/src/build-app.ts line
# 287, and the {"json": …} envelope of its RPCHandler, @orpc/server 1.14.15. The source
# does not settle, so they stay as they were and need an impd sample: whether oRPC adds a
# "meta" field beside "json", the order of the identity's fields, and impd's response
# headers (this stand-in sends Python http.server's Server and Date headers).
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

start_stub_impd() {
  local dir="$1"
  python3 -c "$(
    cat << 'PY'
import os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

out_dir = sys.argv[1]
identity = b'{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}'


class Impd(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        if self.path != "/rpc/tokens/whoami":
            return self.send_refusal()
        good = self.read_good_bearer()
        if good is not None and self.headers.get("authorization") == good:
            return self.send_answer(200, identity)
        self.send_answer(401, b'{"error":"unauthorized"}')

    # http.server routes a request to do_<METHOD> and answers 501 when there is none, so
    # every method but POST resolves here to the refusal, which records it.
    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.send_refusal
        raise AttributeError(name)

    def read_good_bearer(self):
        try:
            with open(os.path.join(out_dir, "good-token")) as token:
                return "Bearer " + token.read()
        except FileNotFoundError:
            return None

    def send_refusal(self):
        with open(os.path.join(out_dir, "unexpected"), "a") as out:
            out.write(f"{self.command} {self.path}\n")
        self.send_answer(500, f'{{"error":"stub-impd: unexpected {self.command} {self.path}"}}'.encode())

    def send_answer(self, status, body):
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


impd = ThreadingHTTPServer(("127.0.0.1", 0), Impd)
with open(os.path.join(out_dir, "port.tmp"), "w") as out:
    out.write(f"{impd.server_address[1]}\n")
os.rename(os.path.join(out_dir, "port.tmp"), os.path.join(out_dir, "port"))
impd.serve_forever()
PY
  )" "$dir" &
  echo "$!" > "$dir/pid"
  wait_for 10 "the impd stand-in to listen" test -f "$dir/port"
}
