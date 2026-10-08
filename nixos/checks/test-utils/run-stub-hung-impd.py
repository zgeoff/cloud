# A stand-in for an impd that has stopped answering, for the impd-local-health check: it
# listens on an ephemeral port on 127.0.0.1, prints that port on one line, and never accepts or
# answers. The kernel still completes each connection into the listen backlog, so a client
# connects and then waits for an answer that never comes, as it would on a hung impd.
#
#   python3 run-stub-hung-impd.py
#
# nixos/checks/test-utils-check.nix tests it.
import signal
import socket

listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(8)
print(listener.getsockname()[1], flush=True)
signal.pause()
