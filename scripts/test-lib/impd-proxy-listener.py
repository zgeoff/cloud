# Stand-ins for the shell suites: impd's tokens.whoami and a proxy that records every
# connection. Usage: python3 impd-proxy-listener.py <dir>, with STUB_GOOD_TOKEN set.
#
# whoami answers the bearer STUB_GOOD_TOKEN with atc-cloud's identity (200, imp's
# {"json": Identity} envelope) and any other caller with impd's 401 {"error":"unauthorized"}.
# The proxy appends "connection" and the first bytes it receives to <dir>/proxy.bytes,
# then closes. Once both listen, <dir>/ports holds "<impd port> <proxy port>".
import os, socket, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

out_dir = sys.argv[1]


class Impd(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        good = self.headers.get("authorization") == "Bearer " + os.environ["STUB_GOOD_TOKEN"]
        if self.path == "/rpc/tokens/whoami" and good:
            status = 200
            body = b'{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}'
        else:
            status, body = 401, b'{"error":"unauthorized"}'
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def run_proxy(server):
    while True:
        conn, _ = server.accept()
        conn.settimeout(2)
        with open(os.path.join(out_dir, "proxy.bytes"), "ab") as out:
            out.write(b"connection\n")
            try:
                out.write(conn.recv(65536))
            except OSError:
                pass
        conn.close()


proxy = socket.socket()
proxy.bind(("127.0.0.1", 0))
proxy.listen()
threading.Thread(target=run_proxy, args=(proxy,), daemon=True).start()
impd = ThreadingHTTPServer(("127.0.0.1", 0), Impd)
with open(os.path.join(out_dir, "ports.tmp"), "w") as out:
    out.write(f"{impd.server_address[1]} {proxy.getsockname()[1]}\n")
os.rename(os.path.join(out_dir, "ports.tmp"), os.path.join(out_dir, "ports"))
impd.serve_forever()
