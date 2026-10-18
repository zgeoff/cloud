# NixOS checks

The checks live in [`nixos/checks/`](../../../../nixos/checks/) and are wired into
`checks.x86_64-linux`. `bun run test:nixos` builds every check the flake declares, from the repo
root as the flake source (`path:.?dir=nixos`), because every check reads `test-support/shell/`. It
builds in a `nixos/nix` container on the `cloud-nixos-checks-store` volume, never the switch's
`geoffcloud-nix-store`.

- [Module checks](#module-checks)
- [Restore rehearsals](#restore-rehearsals)

## Module checks

- A check reads only the shell helpers that
  [`build-shell-lib-source.nix`](../../../../nixos/checks/test-utils/build-shell-lib-source.nix)
  selects, and [`needs-nixos-checks.sh`](../../../../scripts/needs-nixos-checks.sh) lists the same
  files. A helper a check starts to read joins both lists. The checks read nothing else outside
  `nixos/` but `packages/topology/` and the host scripts that `tank-cloud-host-secrets` runs in its
  VM.
- `geoffcloud-eval` evaluates the host's system derivation and builds nothing of the host, so a
  change that breaks the host config fails CI instead of the switch.
- A module check renders its cases through
  [`render-cases.nix`](../../../../nixos/checks/test-utils/render-cases.nix) into `run_cases` calls,
  each in its own fresh directory, with the `assert_*` helpers.
- Shared Nix helpers and stand-ins live in
  [`nixos/checks/test-utils/`](../../../../nixos/checks/test-utils/), one export per file, and the
  [`test-utils`](../../../../nixos/checks/test-utils-check.nix) check tests each of them. Every
  check that uses them depends on that check. The impd stand-ins are compared with the real Elysia
  and Bun versions the pinned imp locks.
- A unit or config is asserted whole: `jq -S` of the evaluated `serviceConfig`, `environment`,
  `description`, `restartTriggers` or generated file against a literal, with store paths
  interpolated by Nix.
- A module assertion has a negative case that evaluates a bad config and compares the failing
  assertion messages exactly.

## Restore rehearsals

- The restore rehearsals (`impd-restore`, `impd-restore-seams`, `impd-restore-saved-failures`) share
  one VM definition,
  [`build-restore-rehearsal.nix`](../../../../nixos/checks/test-utils/build-restore-rehearsal.nix),
  and one reset, `setup_test()`. Each check boots its own VM, and each subtest supplies its own
  scenario data. `impd-restore-reset` checks the reset itself: each subtest leaves one kind of state
  behind, proves it is there, runs `setup_test()` and asserts the whole clean baseline. It also
  resets after a real failed restore, after a real restore killed with SIGKILL while
  [`build-stub-blocking-sqlite3`](../../../../nixos/checks/test-utils/build-stub-blocking-sqlite3.nix)
  holds it, and after a reset stopped part-way, as the shared skill's rule on
  [resetting shared infrastructure](../../testing/SKILL.md#end-to-end-suites) asks. Cleanup that
  depends on what a subtest left lives in the reset, never in scenario flags. This is the language
  form of the shared skill's one [`setupTest`](../../testing/SKILL.md#setuptest) per file.
- `setup_test()` returns the generated system paths as runtime handles, like a temporary directory.
  Each subtest names its restore generation and other scenario values in its own body.
- In a restore rehearsal, each `with subtest("it …")` starts from `setup_test()`, which resets every
  state a subtest can leave. It asserts `machine.execute`'s status and output exactly, masking only
  what the shell compares may mask, plus every side effect the script promises, including the saved
  original on each failure path. Waits use `wait_for_unit`, `wait_until_succeeds` or `wait_for`.
- An error the script declares is reached through real VM state where real state can produce it, and
  through the script's injectable commands (`SQLITE3`, `SYSTEMCTL`, `CMP`, the start loop's pause
  `IMPD_START_SLEEP`, and the health probe's `CURL`) only where it cannot. The start wait is counted
  through [`build-stub-sleep`](../../../../nixos/checks/test-utils/build-stub-sleep.nix) and the
  probe's timeout arguments are checked through
  [`build-stub-curl`](../../../../nixos/checks/test-utils/build-stub-curl.nix), never by waiting out
  a deadline. Two cases wait out a real 1 s curl timeout against the
  [hung impd stand-in](../../../../nixos/checks/test-utils/run-stub-hung-impd.py), with no
  elapsed-time assertion: the stand-in's own test in `test-utils`, which also checks
  `build-stub-curl` against that real curl, and one probe case in `impd-local-health`, the only
  real-transport proof that a hung impd reads as status 0.
- A rehearsal's first subtests assert that no unit failed at boot and that `systemd-detect-virt`
  prints `kvm`, so a run that fell back to emulation fails.
  [`run-nixos-checks.sh`](../../../../scripts/run-nixos-checks.sh) needs a readable and writable KVM
  device for any `impd-restore*` check.
- nixpkgs passes a VM test script as one environment variable, capped at 131,072 bytes. A rehearsal
  that would pass the cap becomes a new `impd-restore-<area>` check, never a shorter rewrite of
  existing subtests.
