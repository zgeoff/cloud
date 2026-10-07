# shellcheck shell=bash
# start_stub_proxy <dir>: starts a stand-in HTTP proxy on an ephemeral loopback port that
# records every connection and answers none, and returns once it listens. <dir>/port then
# holds the port and <dir>/pid the process to kill when the case ends. For each
# connection it appends the line "connection" and the first bytes it receives to
# <dir>/connections, then closes it, so a case that finds no <dir>/connections knows that
# nothing reached the proxy.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

start_stub_proxy() {
  local dir="$1"
  python3 -c "$(
    cat << 'PY'
import os, socket, sys

out_dir = sys.argv[1]
proxy = socket.socket()
proxy.bind(("127.0.0.1", 0))
proxy.listen()
with open(os.path.join(out_dir, "port.tmp"), "w") as out:
    out.write(f"{proxy.getsockname()[1]}\n")
os.rename(os.path.join(out_dir, "port.tmp"), os.path.join(out_dir, "port"))
while True:
    conn, _ = proxy.accept()
    conn.settimeout(2)
    with open(os.path.join(out_dir, "connections"), "ab") as out:
        out.write(b"connection\n")
        try:
            out.write(conn.recv(65536))
        except OSError:
            pass
    conn.close()
PY
  )" "$dir" &
  echo "$!" > "$dir/pid"
  wait_for 10 "the proxy stand-in to listen" test -f "$dir/port"
}
