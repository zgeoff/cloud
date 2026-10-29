# shellcheck shell=bash
# start_stub_stalled_download <dir>: starts a stand-in for a download server whose transfer stalls,
# over plain HTTP on an ephemeral loopback port, and returns once it listens. <dir>/port then holds
# the port, and <dir>/pid the process to kill when the case ends. Point a client at
# http://127.0.0.1:<port>/<any path>.
#
# It answers each GET with 200, a content-length of 1 MiB and the first 4 KiB of the body, then
# sends nothing more and holds the connection open until the client closes it, as a download from a
# CDN that stops moving does. It appends "GET <path>" to <dir>/requests for each GET, in arrival
# order, so a case counts a client's retries there. Every other request fails closed: it appends
# "<method> <path>" to <dir>/unexpected and answers 500 with a body naming the stand-in.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

start_stub_stalled_download() {
  local dir="$1"
  mkdir -p "$dir"
  python3 -c "$(
    cat << 'PY'
import os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

out_dir = sys.argv[1]
records = threading.Lock()


class StalledDownload(BaseHTTPRequestHandler):
    def do_GET(self):
        self.write_line("requests", f"GET {self.path}")
        self.send_response(200)
        self.send_header("content-type", "application/octet-stream")
        self.send_header("content-length", str(1024 * 1024))
        self.end_headers()
        self.wfile.write(b"\0" * 4096)
        self.wfile.flush()
        # an empty read means the client closed the connection
        self.rfile.read(1)

    # http.server routes a request to do_<METHOD> and answers 501 when there is none, so
    # every other method resolves here to the refusal, which records it.
    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.send_refusal
        raise AttributeError(name)

    def send_refusal(self):
        self.write_line("unexpected", f"{self.command} {self.path}")
        body = f"stub-stalled-download: unexpected {self.command} {self.path}".encode()
        self.send_response(500)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def write_line(self, name, line):
        with records, open(os.path.join(out_dir, name), "a") as out:
            out.write(line + "\n")

    def log_message(self, *args):
        pass


ThreadingHTTPServer.daemon_threads = True
server = ThreadingHTTPServer(("127.0.0.1", 0), StalledDownload)
with open(os.path.join(out_dir, "port.tmp"), "w") as out:
    out.write(f"{server.server_address[1]}\n")
os.rename(os.path.join(out_dir, "port.tmp"), os.path.join(out_dir, "port"))
server.serve_forever()
PY
  )" "$dir" &
  echo "$!" > "$dir/pid"
  wait_for 10 "the stalled download stand-in to listen" test -f "$dir/port"
}
