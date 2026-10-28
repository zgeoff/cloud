# shellcheck shell=bash
# start_stub_apt_archive <dir> <port>: starts a stand-in for the Ubuntu archive hosts over plain
# HTTP on 127.0.0.1:<port>, and returns once it listens. It serves the files under <dir>/root by
# path, whatever the Host header names, so one process stands in for archive.ubuntu.com,
# security.ubuntu.com and snapshot.ubuntu.com when /etc/hosts points those names at 127.0.0.1.
# <dir>/pid then holds the process to kill when the case ends. It needs python3.
#
# It answers a GET for a file under <dir>/root with 200 and the file, and a GET for any other path
# with 404, as the archive answers a file it does not hold. A line `<status> <count> <path>` in
# <dir>/faults, read at start, answers that status for the first <count> GETs of <path> instead,
# or for every GET of it when <count> is `all`, as a host in an outage answers.
#
# It appends `<status> <host> <path>` to <dir>/requests for each GET it answers, with the Host
# header's name and no port. Every other method fails closed: it appends `<method> <path>` to
# <dir>/unexpected and answers 500 with a body naming the stand-in.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

start_stub_apt_archive() {
  local dir="$1" port="$2"
  python3 -c "$(
    cat << 'PY'
import os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock

out_dir, port = sys.argv[1], int(sys.argv[2])
root = os.path.realpath(os.path.join(out_dir, "root"))
faults = {}
faults_path = os.path.join(out_dir, "faults")
if os.path.exists(faults_path):
    with open(faults_path) as source:
        for line in source:
            status, count, path = line.split()
            faults[path] = [int(status), None if count == "all" else int(count)]
lock = Lock()


class Archive(BaseHTTPRequestHandler):
    def do_GET(self):
        host = (self.headers.get("host") or "").rsplit(":", 1)[0]
        with lock:
            fault = faults.get(self.path)
            status = None
            if fault is not None and (fault[1] is None or fault[1] > 0):
                status = fault[0]
                if fault[1] is not None:
                    fault[1] -= 1
        file = os.path.realpath(os.path.join(root, self.path.lstrip("/")))
        if status is None:
            status = 200 if file.startswith(root + "/") and os.path.isfile(file) else 404
        self.write_line("requests", f"{status} {host} {self.path}")
        if status != 200:
            return self.send_answer(status, b"")
        with open(file, "rb") as source:
            self.send_answer(200, source.read())

    # http.server routes a request to do_<METHOD> and answers 501 when there is none, so
    # every other method resolves here to the refusal, which records it.
    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.send_refusal
        raise AttributeError(name)

    def send_refusal(self):
        self.write_line("unexpected", f"{self.command} {self.path}")
        self.send_answer(500, f"stub-apt-archive: unexpected {self.command} {self.path}".encode())

    def write_line(self, name, line):
        with lock, open(os.path.join(out_dir, name), "a") as out:
            out.write(line + "\n")

    def send_answer(self, status, body):
        self.send_response(status)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


archive = ThreadingHTTPServer(("127.0.0.1", port), Archive)
with open(os.path.join(out_dir, "listening"), "w") as out:
    out.write("\n")
archive.serve_forever()
PY
  )" "$dir" "$port" &
  echo "$!" > "$dir/pid"
  wait_for 10 "the apt archive stand-in to listen" test -f "$dir/listening"
}
