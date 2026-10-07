# A stand-in impd for the impd-local-health check: answers every GET with one status, content
# type and body, given as arguments, over HTTP/1.1 as Bun does.
#
#   python3 start-stub-impd.py STATUS CONTENT_TYPE BODY
#
# It listens on an ephemeral port on 127.0.0.1 and prints that port on one line once it accepts.
# The shapes the check passes are impd's, as the pinned imp answers them (Elysia 1.4.29 on Bun
# 1.4.2): /health is 200, "application/json;charset=utf-8", {"status":"ok","ready":true}
# (packages/daemon/src/build-app.ts), and a route no handler matches is 404,
# "text/plain;charset=utf-8", NOT_FOUND (Elysia's default, which build-app.ts keeps).
# nixos/checks/test-utils-check.nix tests it and pins those shapes to imp's source.
import http.server
import sys

status, content_type, body = int(sys.argv[1]), sys.argv[2], sys.argv[3].encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
