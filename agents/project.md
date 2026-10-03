# cloud

Infrastructure as code for `geoff.cloud`, Geoff's general-purpose private cloud on the tailnet:
today one Onidel VM running a single-node k3s cluster, with imp microVMs on the host as the first
workload. `docs/architecture.md` is the design; issue #1 tracks the work.

## Layout

Bun workspace. `infra/` is the Pulumi program (TypeScript, Bun runtime). `provider/` is the partial
Onidel Pulumi provider, a Go module built with `pulumi-go-provider`'s `infer` package. `sdk/onidel/`
is its generated TypeScript SDK: never edit it by hand, regenerate it. `nixos/` is the host flake.
`docs/` holds the architecture and runbooks. `scripts/` holds repo tooling.

## Rules

- Every change lands through a squash PR. The `main protection` ruleset blocks a direct push to
  `main` and needs the `checks` and `gitleaks` checks green.
- CodeRabbit is not installed on this repo, so a PR here gets no bot review.
- This repo is public. Never commit a secret. Secrets live in the 1Password `cloud` vault; `.env`
  holds only `op://` references, resolved with `op run --env-file=.env -- <command>`.
- Never print a secret, and never log a whole Onidel VM object: the API returns the root password.
- No live change without a preview first. The Tailscale policy file in particular: Pulumi's `Acl`
  replaces the whole file, so Geoff reviews the diff before an apply that changes it.
- The host's firewall is NixOS's table `inet nixos-fw`. imp's module adds `inet imp-forward`, and
  k3s and Docker add their own tables; imp's `inet imp_egress` lives inside the imp-host container.
  Never `flush ruleset`, and keep `networking.nftables.flushRuleset` off.
- Never touch `/dev/vdb` on the host. It holds imp's ZFS pool.
- Everything the hooks and CI run is a root `package.json` script.

## Host operations

- Switch geoffcloud from a `nixos/nix` container on the host network; Tailscale SSH authenticates
  `root@geoffcloud`. Build first with `nixos-rebuild build`, then switch from a clean checkout of
  `main`:

  ```sh
  docker run --rm --network host -v geoffcloud-nix-store:/nix -v "$PWD":/src:ro \
    -v ~/.ssh/known_hosts:/root/.ssh/known_hosts:ro -w /src -e NIX_SSHOPTS="-o BatchMode=yes" \
    nixos/nix sh -c 'nix --extra-experimental-features "nix-command flakes" \
      shell nixpkgs#openssh nixpkgs#nixos-rebuild -c nixos-rebuild switch \
      --flake path:./nixos#geoffcloud --target-host root@geoffcloud'
  ```

- Before a switch that changes imp, copy impd's database with
  `bash scripts/copy-impd-db.sh <label>`: a `VACUUM INTO` copy taken inside imp-host while impd
  runs, with its integrity check, schema migration and imp version in `COPY-INFO`. Never tar the
  live `imp.sqlite*` files: impd runs in WAL mode, so such a copy can tear. A restore is one-way
  (migrations run forward only), needs approval, and follows the restore runbook (#9). The host's
  `/var/lib/imp` is empty: `tank/imp` has a legacy mountpoint inside imp-host.
- Drift checks are manual. `bun run drift` is a refresh preview that exits non-zero on any change.
  Before an apply, run it from a clean checkout of the last deployed revision; a clean `main` serves
  only when it is fully applied, because it can hold other unapplied changes. Record that revision
  and the result. Then `bun run preview -- --refresh` from a clean current `main` must show only the
  intended changes, reviewed on their PRs; apply them with `bun run up`, then run `bun run drift`
  again. Record both drift results. A scheduled CI check is parked until scoped credentials exist
  (#19): Onidel offers only full-account keys.
- impd owns the DNS records `imps.geoff.cloud`, `*.imps.geoff.cloud` and
  `_acme-challenge.imps.geoff.cloud`. Pulumi must never declare them.

## Project management

Geoff runs this project through a delegated coordinating agent, which reaches sessions through atc
(2026-10-03). Its word is Geoff's sign-off; Geoff is the final rubber stamp.

- Escalate anything you doubt through the coordinating agent; it brings Geoff in directly.
- Before an action that costs money, deletes data or cannot be undone, state its exact effect back
  to it and act only on its approval of that statement, not of a summary.
- A permission-check block needs Geoff himself. Tell the coordinating agent, so it can bring him in.
