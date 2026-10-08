# A stand-in impd for the impd-local-health check: answers a GET of one path with one status,
# content type and body, given as arguments, over HTTP/1.1 as Bun does, and records every
# request it gets as one line, "<method> <path>", in a log file.
#
#   python3 run-stub-impd.py PATH STATUS CONTENT_TYPE BODY REQUEST_LOG
#
# It listens on an ephemeral port on 127.0.0.1 and prints that port on one line once it accepts.
# A request it does not expect, any other method or path, is recorded too and answered with a
# failure: 500, text/plain, "unexpected request: <method> <path>"; to a HEAD, as HTTP has it,
# with the headers alone. The shapes the check passes
# are impd's, as the pinned imp answers them (Elysia 1.4.29 on Bun 1.4.2): /health is 200,
# "application/json;charset=utf-8", {"status":"ok","ready":true}
# (packages/daemon/src/build-app.ts), and a route no handler matches is 404,
# "text/plain;charset=utf-8", NOT_FOUND (Elysia's default, which build-app.ts keeps).
# nixos/checks/test-utils-check.nix tests it and pins those shapes to imp's source.
import http.server
import sys

path = sys.argv[1]
status, content_type, body = int(sys.argv[2]), sys.argv[3], sys.argv[4].encode()
request_log = sys.argv[5]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_reply(self):
        with open(request_log, "a") as log:
            log.write(f"{self.command} {self.path}\n")
        if self.command == "GET" and self.path == path:
            self.send(status, content_type, body)
        else:
            self.send(500, "text/plain", f"unexpected request: {self.command} {self.path}".encode())

    def send(self, code, kind, payload):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = send_reply

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
