# shellcheck shell=bash
# start_stub_github_api <dir>: starts a stand-in for a GitHub Enterprise host's API over
# HTTPS on an ephemeral loopback port, for a repository with no releases, and returns once
# it listens. <dir>/port then holds the port, <dir>/pid the process to kill when the case
# ends, and <dir>/cert.pem the self-signed certificate (for 127.0.0.1) it serves: point gh
# at it with GH_HOST=127.0.0.1:<port> and SSL_CERT_FILE=<dir>/cert.pem, which Go's TLS
# reads on Linux, so nothing outside the case trusts it.
#
# It answers the two lookups `gh release download <tag>` sends at once (cli/cli's
# FetchRelease), so that both report the tag as missing, whichever lands first:
#
# - GET /api/v3/repos/<owner>/<repo>/releases/tags/<tag>: 404 with GitHub's not-found
#   body (gh reads only the status);
# - POST /api/graphql with the RepositoryReleaseByTag query: 200 with a null release, as
#   GitHub answers for a tag that has none.
#
# It appends "<method> <path>" for each request it answers, and the GraphQL body after the
# path without the newline gh ends it with, to <dir>/requests. Every other request fails closed: it appends "<method> <path>" to
# <dir>/unexpected and answers 500 with a body naming the stand-in.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

start_stub_github_api() {
  local dir="$1"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" 2> /dev/null
  python3 -c "$(
    cat << 'PY'
import json, os, re, ssl, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

out_dir = sys.argv[1]
not_found = b'{"message":"Not Found","documentation_url":"https://docs.github.com/rest/releases/releases#get-a-release-by-tag-name","status":"404"}'
no_release = b'{"data":{"repository":{"release":null}}}'


class GitHubAPI(BaseHTTPRequestHandler):
    def do_GET(self):
        if not re.fullmatch(r"/api/v3/repos/[^/]+/[^/]+/releases/tags/[^/]+", self.path):
            return self.send_refusal()
        self.write_line("requests", f"GET {self.path}")
        self.send_answer(404, not_found)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0))).decode()
        try:
            query = json.loads(body).get("query", "")
        except ValueError:
            query = ""
        if self.path != "/api/graphql" or not query.startswith("query RepositoryReleaseByTag("):
            return self.send_refusal()
        self.write_line("requests", f"POST {self.path} {body.rstrip()}")
        self.send_answer(200, no_release)

    # http.server routes a request to do_<METHOD> and answers 501 when there is none, so
    # every other method resolves here to the refusal, which records it.
    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.send_refusal
        raise AttributeError(name)

    def send_refusal(self):
        self.write_line("unexpected", f"{self.command} {self.path}")
        self.send_answer(500, f'{{"message":"stub-github-api: unexpected {self.command} {self.path}"}}'.encode())

    def write_line(self, name, line):
        with open(os.path.join(out_dir, name), "a") as out:
            out.write(line + "\n")

    def send_answer(self, status, body):
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


api = ThreadingHTTPServer(("127.0.0.1", 0), GitHubAPI)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(os.path.join(out_dir, "cert.pem"), os.path.join(out_dir, "key.pem"))
api.socket = tls.wrap_socket(api.socket, server_side=True)
with open(os.path.join(out_dir, "port.tmp"), "w") as out:
    out.write(f"{api.server_address[1]}\n")
os.rename(os.path.join(out_dir, "port.tmp"), os.path.join(out_dir, "port"))
api.serve_forever()
PY
  )" "$dir" &
  echo "$!" > "$dir/pid"
  wait_for 10 "the GitHub API stand-in to listen" test -f "$dir/port"
}
