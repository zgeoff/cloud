# shellcheck shell=bash
# start_stub_discord_webhook <dir>: starts a stand-in for a Discord webhook over plain HTTP on an
# ephemeral loopback port, and returns once it listens. <dir>/port then holds the port, and
# <dir>/pid the process to kill when the case ends. Point a client at
# http://127.0.0.1:<port>/api/webhooks/<id>/<token>.
#
# It takes a JSON POST to /api/webhooks/<digits>/<token> as Discord's execute-webhook does without
# ?wait=true: 204 and no body. While <dir>/status holds a code of 400 or above, which it reads at
# each request, it answers that code with Discord's error body instead,
# {"message": "<code>: stub-discord-webhook", "code": 0}. Either way it appends "POST <path>" to
# <dir>/requests and writes the body, as received, to <dir>/bodies/<n>.json, numbered from 1 in
# arrival order. Every other request fails closed: it appends "<method> <path>" to
# <dir>/unexpected and answers 500 with a body naming the stand-in.
#
# Not checked against Discord, since no test reaches the internet. Checked on 2026-10-19 against
# https://discord.com/developers/docs/resources/webhook#execute-webhook (204 No Content unless
# ?wait=true) and https://discord.com/developers/docs/reference#error-messages (an error body holds
# a message and a code). The docs leave the message of a server error unsettled, so the stand-in
# names itself there.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

start_stub_discord_webhook() {
  local dir="$1"
  mkdir -p "$dir/bodies"
  python3 -c "$(
    cat << 'PY'
import json, os, re, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

out_dir = sys.argv[1]

# the server answers each request on its own thread, and posts that arrive together must still
# take one number each
records = threading.Lock()


class DiscordWebhook(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        if (
            not re.fullmatch(r"/api/webhooks/[0-9]+/[A-Za-z0-9_-]+", self.path)
            or self.headers.get("content-type", "").split(";")[0].strip() != "application/json"
        ):
            return self.send_refusal()
        with records:
            self.write_line("requests", f"POST {self.path}")
            count = len(os.listdir(os.path.join(out_dir, "bodies"))) + 1
            with open(os.path.join(out_dir, "bodies", f"{count}.json"), "wb") as out:
                out.write(body)
        status = self.read_status()
        if status >= 400:
            return self.send_answer(status, json.dumps({"message": f"{status}: stub-discord-webhook", "code": 0}).encode())
        self.send_answer(204, b"")

    # http.server routes a request to do_<METHOD> and answers 501 when there is none, so
    # every other method resolves here to the refusal, which records it.
    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.send_refusal
        raise AttributeError(name)

    def read_status(self):
        try:
            with open(os.path.join(out_dir, "status")) as source:
                return int(source.read().strip())
        except FileNotFoundError:
            return 204

    def send_refusal(self):
        self.write_line("unexpected", f"{self.command} {self.path}")
        self.send_answer(500, f'{{"message":"stub-discord-webhook: unexpected {self.command} {self.path}"}}'.encode())

    def write_line(self, name, line):
        with open(os.path.join(out_dir, name), "a") as out:
            out.write(line + "\n")

    def send_answer(self, status, body):
        self.send_response(status)
        if body:
            self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), DiscordWebhook)
with open(os.path.join(out_dir, "port.tmp"), "w") as out:
    out.write(f"{server.server_address[1]}\n")
os.rename(os.path.join(out_dir, "port.tmp"), os.path.join(out_dir, "port"))
server.serve_forever()
PY
  )" "$dir" &
  echo "$!" > "$dir/pid"
  wait_for 10 "the Discord webhook stand-in to listen" test -f "$dir/port"
}
