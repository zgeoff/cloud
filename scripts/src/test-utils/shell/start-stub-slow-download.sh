# shellcheck shell=bash
# start_stub_slow_download <dir> <size> <bytes per second>: starts a stand-in for a download server
# whose every connection runs slowly, over plain HTTP on an ephemeral loopback port, and returns once
# it listens. <dir>/port then holds the port, <dir>/pid the process to kill when the case ends, and
# <dir>/body the <size> bytes it serves at every path. Point a client at
# http://127.0.0.1:<port>/<any path>.
#
# It answers a GET with 200 and the whole body, and a GET with `Range: bytes=<first>-` with 206, a
# content-range and the bytes from <first> on, as Google's storage answers a resumed download. A
# <first> at or past the end gets 416 with `content-range: bytes */<size>`. It sends the body in
# 4 KiB writes, paced to <bytes per second>, so each connection runs at that speed. At a speed of 0
# it sends the headers and then nothing, and holds the connection open until the client closes it.
# It appends "GET <path> <range header or ->" to <dir>/requests for each GET, in arrival order, so
# a case reads where each attempt resumed. Every other request fails closed: it appends
# "<method> <path>" to <dir>/unexpected and answers 500 with a body naming the stand-in.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

start_stub_slow_download() {
  local dir="$1" size="$2" rate="$3"
  mkdir -p "$dir"
  python3 -I -c "$(
    cat << 'PY'
import os, re, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

out_dir, size, rate = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
body = (bytes(range(256)) * (size // 256 + 1))[:size]
with open(os.path.join(out_dir, "body"), "wb") as out:
    out.write(body)
records = threading.Lock()
chunk = 4096


class SlowDownload(BaseHTTPRequestHandler):
    def do_GET(self):
        header = self.headers.get("Range")
        self.write_line("requests", f"GET {self.path} {header or '-'}")
        first = 0
        if header is None:
            self.send_response(200)
        else:
            first = int(re.fullmatch(r"bytes=(\d+)-", header).group(1))
            if first >= size:
                self.send_response(416)
                self.send_header("content-range", f"bytes */{size}")
                self.send_header("content-length", "0")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("content-range", f"bytes {first}-{size - 1}/{size}")
        self.send_header("content-type", "application/octet-stream")
        self.send_header("content-length", str(size - first))
        self.end_headers()
        self.wfile.flush()
        if rate == 0:
            # an empty read means the client closed the connection
            self.rfile.read(1)
            return
        for start in range(first, size, chunk):
            try:
                self.wfile.write(body[start : start + chunk])
                self.wfile.flush()
            except OSError:
                return
            time.sleep(chunk / rate)

    # http.server routes a request to do_<METHOD> and answers 501 when there is none, so
    # every other method resolves here to the refusal, which records it.
    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.send_refusal
        raise AttributeError(name)

    def send_refusal(self):
        self.write_line("unexpected", f"{self.command} {self.path}")
        body = f"stub-slow-download: unexpected {self.command} {self.path}".encode()
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
server = ThreadingHTTPServer(("127.0.0.1", 0), SlowDownload)
with open(os.path.join(out_dir, "port.tmp"), "w") as out:
    out.write(f"{server.server_address[1]}\n")
os.rename(os.path.join(out_dir, "port.tmp"), os.path.join(out_dir, "port"))
server.serve_forever()
PY
  )" "$dir" "$size" "$rate" &
  echo "$!" > "$dir/pid"
  wait_for 10 "the slow download stand-in to listen" test -f "$dir/port"
}
