# shellcheck shell=bash
# create_stub_racing_restic <bin> <real restic> <race script> <state>: writes <bin>/restic, a
# /bin/sh stand-in for restic that runs <race script> with /bin/sh at the one moment no real state
# reaches: right before the first `restore` call, after the caller has picked what to restore. It
# runs the script once, marks <state>/raced and appends ["restic-raced"] to <state>/log, then hands
# the call to <real restic>. When the script fails, the stand-in exits with its status and runs no
# restic. Every other call goes to <real restic> unchanged. The paths are the ones the stand-in sees
# where it runs, such as inside a container.
create_stub_racing_restic() {
  local bin="$1" real_restic="$2" race_script="$3" state="$4"
  cat > "$bin/restic" << STUB
#!/bin/sh
case " \$* " in
  *" restore "*)
    if [ ! -e "$state/raced" ]; then
      : > "$state/raced"
      /bin/sh "$race_script" || exit
      echo '["restic-raced"]' >> "$state/log"
    fi
    ;;
esac
exec "$real_restic" "\$@"
STUB
  chmod +x "$bin/restic"
}
