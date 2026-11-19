# shellcheck shell=bash
# create_stub_checks_docker <bin>: writes <bin>/docker, a stand-in for the docker that
# run-nixos-checks.sh runs nix in. It logs each call's argv as a JSON line to STUB_LOG:
#
# - a `run … eval --raw path:/src?dir=nixos#checks.x86_64-linux --apply …`: prints STUB_CHECKS
#   with no trailing newline, as `nix eval --raw` prints a string, or, when STUB_EVAL_ERROR is
#   set, prints it on stderr and exits 1, nix's exit for a failed evaluation;
# - a `run … path-info --derivation …`: copies the directory mounted at /src (its `<dir>:/src:ro`
#   argument) to STUB_SOURCE_SAW, in place of an earlier call's copy, then, when
#   STUB_DERIVATION_ERROR is set, prints it on stderr and exits 1, nix's exit for a failed
#   evaluation; otherwise it prints one line for each
#   `path:/src?dir=nixos#checks.x86_64-linux.<name>` argument,
#   /nix/store/00000000000000000000000000000000-<name>.drv, as nix prints each derivation's path;
# - a `run … build --no-link -L …`: when STUB_BUILD_ERROR is set, prints it on stderr and exits 1,
#   nix's exit for a failed build;
# - a `run … nix-store -qR --include-outputs …`, which write-nixos-checks-cache.sh runs: prints the
#   file STUB_CLOSURE, one store path per line, as nix-store prints a closure;
# - a `run … path-info --json --stdin`: reads its stdin, then prints the file STUB_PATH_INFO, the
#   JSON nix prints for those paths;
# - a `run … copy --no-recursive --stdin --to file:///cache?compression=zstd`: writes to the folder
#   mounted at /cache (its `<dir>:/cache` argument) the nix-cache-info a binary cache opens with,
#   and for each store path on stdin a `<hash>.narinfo` that names it, in place of the real
#   narinfo and its compressed NAR. As nix 2.35.2 does, it first refuses, with nix's error and
#   exit 1, a path with a reference, in the references STUB_PATH_INFO lists for it, that is
#   neither on stdin nor has a `<hash>.narinfo` in the folder;
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# Nix documents no exit-code table for these commands, so the exit 1 was checked on
# 2026-10-08 against the real nix: nix 2.35.2 in the pinned image
# (nixos/nix:2.35.2@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c,
# scripts/nix-image.sh), in a container without network. A failed `nix eval --raw`, a `nix
# build` whose builder exits 1 and a `nix copy --to ssh://` to a refused port each
# exited 1. On 2026-10-15 the same image's `nix path-info --derivation` exited 1 for a check
# that fails to evaluate. On 2026-10-28 its `nix copy --no-recursive` to a file cache exited 1 for
# a path whose reference the cache lacked, and copied the path once a narinfo for the reference
# was in the cache. A later image could change the exit, and nix's manual gives 100-and-up codes for
# some build failures under `nix-store --realise`, which this check did not reach.
create_stub_checks_docker() {
  local bin="$1"
  cat > "$bin/docker" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
case "$*" in
  "run "*" eval --raw path:/src?dir=nixos#checks.x86_64-linux --apply "*)
    if [ -n "${STUB_EVAL_ERROR:-}" ]; then echo "$STUB_EVAL_ERROR" >&2; exit 1; fi
    printf '%s' "$STUB_CHECKS"
    ;;
  "run "*" path-info --derivation "*)
    src=""
    for arg in "$@"; do
      case "$arg" in *":/src:ro") src="${arg%:/src:ro}" ;; esac
    done
    rm -rf "$STUB_SOURCE_SAW"
    cp -R "$src" "$STUB_SOURCE_SAW"
    if [ -n "${STUB_DERIVATION_ERROR:-}" ]; then echo "$STUB_DERIVATION_ERROR" >&2; exit 1; fi
    for arg in "$@"; do
      case "$arg" in
        "path:/src?dir=nixos#checks.x86_64-linux."*)
          echo "/nix/store/00000000000000000000000000000000-${arg#path:/src?dir=nixos#checks.x86_64-linux.}.drv"
          ;;
      esac
    done
    ;;
  "run "*" build --no-link -L "*)
    if [ -n "${STUB_BUILD_ERROR:-}" ]; then echo "$STUB_BUILD_ERROR" >&2; exit 1; fi
    ;;
  "run "*" nix-store -qR --include-outputs "*)
    cat "$STUB_CLOSURE"
    ;;
  "run "*" path-info --json --stdin")
    cat > /dev/null
    cat "$STUB_PATH_INFO"
    ;;
  "run "*" copy --no-recursive --stdin --to file:///cache?compression=zstd")
    cache=""
    for arg in "$@"; do
      case "$arg" in *":/cache") cache="${arg%:/cache}" ;; esac
    done
    mapfile -t paths
    for path in "${paths[@]}"; do
      references=()
      if [ -n "${STUB_PATH_INFO:-}" ]; then
        mapfile -t references < <(jq -r --arg path "$path" '.[$path].references // [] | .[]' "$STUB_PATH_INFO")
      fi
      for reference in "${references[@]}"; do
        name="${reference#/nix/store/}"
        if ! printf '%s\n' "${paths[@]}" | grep -qxF "$reference" && [ ! -f "$cache/${name%%-*}.narinfo" ]; then
          echo "error: cannot add '$path' to the binary cache because the reference '$reference' is not valid" >&2
          exit 1
        fi
      done
    done
    printf 'StoreDir: /nix/store\n' > "$cache/nix-cache-info"
    for path in "${paths[@]}"; do
      name="${path#/nix/store/}"
      printf 'StorePath: %s\n' "$path" > "$cache/${name%%-*}.narinfo"
    done
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/docker"
}
