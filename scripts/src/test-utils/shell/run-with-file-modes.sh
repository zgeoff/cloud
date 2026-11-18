# shellcheck shell=bash
# run_with_file_modes <command> [<arg>…]: runs the command so that a file's mode binds it as it
# binds a user who is not root, and returns the command's exit status. Root passes a mode that
# denies a write, a read or a search through CAP_DAC_OVERRIDE, CAP_DAC_READ_SEARCH and CAP_FOWNER,
# so a case that tests a denied write, run as root, sees the write succeed. As uid 0, the command
# runs under setpriv with those three capabilities gone from its bounding and inheritable sets, so
# neither it nor any program it runs regains them; it keeps uid 0, so it still owns the case tree
# and its owner bits apply. As any other user, the command runs unchanged.
run_with_file_modes() {
  if [ "$(id -u)" = 0 ]; then
    setpriv --bounding-set=-dac_override,-dac_read_search,-fowner \
      --inh-caps=-dac_override,-dac_read_search,-fowner -- "$@"
  else
    "$@"
  fi
}
