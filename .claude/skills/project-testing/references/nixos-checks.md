# NixOS checks

These rules add to [NixOS testing](../../testing/references/nixos.md) for the checks in
[`nixos/checks/`](../../../../nixos/checks/). Register a new check as an attribute of
`checks.x86_64-linux` in [`nixos/flake.nix`](../../../../nixos/flake.nix), and build it with
`bun run test:nixos <check>`.

- [Module checks](#module-checks)
- [Restore rehearsals](#restore-rehearsals)

## Module checks

- Keep a check's inputs to `nixos/`, `packages/topology/` and the shell helpers that
  [`build-shell-lib-source.nix`](../../../../nixos/checks/test-utils/build-shell-lib-source.nix)
  selects. `tank-cloud-host-secrets` also reads the host scripts it runs in its VM. When a check
  starts to source another helper from `test-support/shell/`, add the file's path to that list and
  to the `nixos` gate of [`gates.yml`](../../../../.github/gates.yml).
- Render a module check's cases through
  [`render-cases.nix`](../../../../nixos/checks/test-utils/render-cases.nix) into `run_cases` calls.
- Put a shared Nix helper or stand-in in
  [`nixos/checks/test-utils/`](../../../../nixos/checks/test-utils/), one export per file, with a
  test in [`test-utils-check.nix`](../../../../nixos/checks/test-utils-check.nix). Import that check
  in each check that uses the helper, as
  [`impd-db-tools.nix`](../../../../nixos/checks/impd-db-tools.nix) does.
- Assert a unit or a generated file whole. Compare `jq -S` of the evaluated `serviceConfig`,
  `environment`, `description` and `restartTriggers` with one literal, and interpolate store paths
  from Nix.
- Give each module assertion a case that evaluates a bad config, and compare the failing assertion
  messages exactly.

## Restore rehearsals

The `impd-restore*` checks share one VM definition,
[`build-restore-rehearsal.nix`](../../../../nixos/checks/test-utils/build-restore-rehearsal.nix), and
one reset function, `setup_test()`, which returns the VM to a clean baseline.
`impd-restore-reset` tests that function.

- Start each `with subtest("it …")` from `setup_test()`. When a subtest leaves state behind, clean it
  up in `setup_test()`, never through a flag the subtest passes.
- Write the restore generation and every value the subtest asserts later, such as a marker or a
  secret, in the subtest's own body.
- Assert `machine.execute`'s status and output exactly. Assert each file the script writes or keeps
  too, such as the saved original on each failure path.
- Reach an error through real VM state when the VM can produce it. Otherwise set one of the script's
  command variables on the `machine.execute` line, as in `SQLITE3=${stubSqlite3}`.
- Count the start wait through
  [`build-stub-sleep`](../../../../nixos/checks/test-utils/build-stub-sleep.nix), and check the
  probe's timeout arguments through
  [`build-stub-curl`](../../../../nixos/checks/test-utils/build-stub-curl.nix). Never wait for a real
  deadline to pass.
- Begin each rehearsal with subtests that assert no unit failed at boot and that
  `systemd-detect-virt` prints `kvm`, so a run that fell back to emulation fails.
- When a rehearsal would pass the 131,072-byte limit nixpkgs puts on a VM test script, copy an
  existing `impd-restore-*` check into a new one named for the failure paths it covers. Never shorten
  the existing subtests to fit.
