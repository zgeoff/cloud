# shellcheck shell=bash
# pick_port: prints a free TCP port on 127.0.0.1, one the kernel hands out for an ephemeral bind and
# that the helper releases before it returns, for a server the case starts next.
pick_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}
