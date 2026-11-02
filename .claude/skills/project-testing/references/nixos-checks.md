# NixOS checks

These rules add to [NixOS testing](../../testing/references/nixos.md) for the checks in
[`nixos/checks/`](../../../../nixos/checks/). `bun run test:nixos [check…]` builds them in a
`nixos/nix` container on the `cloud-nixos-checks-store` volume, never the switch's
`geoffcloud-nix-store`.

- [Module checks](#module-checks)
- [Restore rehearsals](#restore-rehearsals)

## Module checks

- When a check starts to read a shell helper, add it to
  [`build-shell-lib-source.nix`](../../../../nixos/checks/test-utils/build-shell-lib-source.nix) and
  to the `nixos` gate of [`gates.yml`](../../../../.github/gates.yml). Never read anything else
  outside `nixos/` but `packages/topology/` and the host scripts that `tank-cloud-host-secrets` runs
  in its VM.
- Render a module check's cases through
  [`render-cases.nix`](../../../../nixos/checks/test-utils/render-cases.nix) into `run_cases` calls.
- Put a shared Nix helper or stand-in in
  [`nixos/checks/test-utils/`](../../../../nixos/checks/test-utils/), one export per file, with a
  test in the [`test-utils`](../../../../nixos/checks/test-utils-check.nix) check. Make each check
  that uses it depend on that check.
- Assert a unit or config whole: `jq -S` of the evaluated `serviceConfig`, `environment`,
  `description`, `restartTriggers` or generated file against a literal, with store paths
  interpolated by Nix.
- Give each module assertion a case that evaluates a bad config and compares the failing assertion
  messages exactly.

## Restore rehearsals

The `impd-restore*` checks share one VM definition,
[`build-restore-rehearsal.nix`](../../../../nixos/checks/test-utils/build-restore-rehearsal.nix), and
one reset, `setup_test()`. `impd-restore-reset` tests the reset itself.

- Start each `with subtest("it …")` from `setup_test()`. Put cleanup that depends on what a subtest
  left in the reset, never in a scenario flag.
- Name the restore generation and every value a subtest later asserts, such as a marker or a secret,
  in the subtest's own body.
- Assert `machine.execute`'s status and output exactly, plus every side effect the script documents,
  including the saved original on each failure path.
- Reach a declared error through real VM state where it can. Use the script's injectable commands
  (`SQLITE3`, `SYSTEMCTL`, `CMP`, `IMPD_START_SLEEP`, `CURL`) only where it can't.
- Count the start wait through
  [`build-stub-sleep`](../../../../nixos/checks/test-utils/build-stub-sleep.nix), and check the
  probe's timeout arguments through
  [`build-stub-curl`](../../../../nixos/checks/test-utils/build-stub-curl.nix). Never wait out a
  deadline in a new case.
- Begin each rehearsal with subtests that assert no unit failed at boot and that
  `systemd-detect-virt` prints `kvm`, so a run that fell back to emulation fails. The checks need a
  readable and writable KVM device.
- When a rehearsal would pass the 131,072-byte limit nixpkgs puts on a VM test script, start a new
  `impd-restore-<area>` check. Never shorten the existing subtests to fit.
