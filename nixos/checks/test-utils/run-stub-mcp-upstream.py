# A stand-in for impd's public MCP listener, for the public-front-vm check: it records every
# request it gets as one JSON line, {"method", "path", "host", "authorization"}, in a log file, and
# answers each with 200, text/plain, "<method> <path>". A GET of /mcp gets an event stream instead,
# as an MCP client's GET opens one: the event "first" at once, then the event "second" once the
# release file exists, then the end of the stream. The path is the request target as it arrived,
# so a front that rewrote it shows in the log.
#
#   python3 run-stub-mcp-upstream.py PORT REQUEST_LOG RELEASE_FILE
#
# It listens on PORT on 127.0.0.1, or on an ephemeral port for 0, and prints the port on one line
# once it accepts. nixos/checks/test-utils-check.nix tests it.
import http.server
import json
import os
import sys
import time

port = int(sys.argv[1])
request_log, release_file = sys.argv[2], sys.argv[3]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_reply(self):
        with open(request_log, "a") as log:
            entry = {
                "method": self.command,
                "path": self.path,
                "host": self.headers.get("Host"),
                "authorization": self.headers.get("Authorization"),
            }
            log.write(json.dumps(entry) + "\n")
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.command == "GET" and self.path == "/mcp":
            self.send_stream()
        else:
            self.send_text(f"{self.command} {self.path}".encode())

    def send_text(self, payload):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def send_stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(b"data: first\n\n")
        self.wfile.flush()
        while not os.path.exists(release_file):
            time.sleep(0.1)
        self.wfile.write(b"data: second\n\n")
        self.wfile.flush()
        self.close_connection = True

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = send_reply

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
