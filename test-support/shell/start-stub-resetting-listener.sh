# shellcheck shell=bash
# start_stub_resetting_listener <dir>: starts a loopback listener on an ephemeral port that
# resets every connection, and returns once it listens. <dir>/port then holds the port and
# <dir>/pid the process to kill when the case ends. For each connection it appends the
# line "connection" to <dir>/connections, reads the first bytes the client sends, then
# closes with SO_LINGER 0, so the kernel sends a RST instead of a FIN. Reading first
# makes the reset land while the client waits for an answer, as a peer that drops the
# connection mid-request does, rather than while it is still sending.
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

start_stub_resetting_listener() {
  local dir="$1"
  python3 -c "$(
    cat << 'PY'
import os, socket, struct, sys

out_dir = sys.argv[1]
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen()
with open(os.path.join(out_dir, "port.tmp"), "w") as out:
    out.write(f"{listener.getsockname()[1]}\n")
os.rename(os.path.join(out_dir, "port.tmp"), os.path.join(out_dir, "port"))
while True:
    conn, _ = listener.accept()
    with open(os.path.join(out_dir, "connections"), "a") as out:
        out.write("connection\n")
    conn.settimeout(2)
    try:
        conn.recv(65536)
    except OSError:
        pass
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    conn.close()
PY
  )" "$dir" &
  echo "$!" > "$dir/pid"
  wait_for 10 "the resetting listener to listen" test -f "$dir/port"
}
