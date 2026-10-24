# A stand-in model API for the geoffcloud-spend-cap check: answers a POST of one path with one
# JSON body, given as an argument, as a 200 over HTTP/1.1, and records every request it gets as
# one line, "<method> <path>", in a log file, after it reads the request's body.
#
#   python3 run-stub-model-api.py PATH BODY REQUEST_LOG
#
# It listens on an ephemeral port on 127.0.0.1 and prints that port on one line once it accepts.
# A request it does not expect, any other method or path, is recorded too and answered with a
# failure: 500, text/plain, "unexpected request: <method> <path>". The check passes a whole,
# unstreamed Messages API reply, whose usage object holds input_tokens, cache_creation_input_tokens,
# cache_read_input_tokens and output_tokens, as Anthropic's Messages API reference gives it
# (platform.claude.com/docs/en/api/messages, checked 24 Oct 2026).
# nixos/checks/test-utils-check.nix tests it.
import http.server
import sys

path = sys.argv[1]
body = sys.argv[2].encode()
request_log = sys.argv[3]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_reply(self):
        self.read_body()
        with open(request_log, "a") as log:
            log.write(f"{self.command} {self.path}\n")
        if self.command == "POST" and self.path == path:
            self.send(200, "application/json", body)
        else:
            self.send(
                500,
                "text/plain",
                f"unexpected request: {self.command} {self.path}".encode(),
            )

    # a proxy that forwards the caller's body as a stream sends it chunked, with no Content-Length
    def read_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() != "chunked":
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            return
        while True:
            size = int(self.rfile.readline().split(b";")[0], 16)
            self.rfile.read(size + 2)
            if size == 0:
                return

    def send(self, code, kind, payload):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = send_reply

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
