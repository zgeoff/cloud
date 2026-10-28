# Compares the imp release the flake input pins (its package.json version) with the tag of the
# imp-host image that services.imp.image pins, and returns one message per mismatch: [ ] when they
# agree. The module and the image move together (scripts/release/run-release-pin.ts), so a pin
# of one without the other runs a module against an image of another release. checks/imp-pin.nix runs it on
# geoffcloud's config and tests it.
{ lib }:
{ releaseVersion, image }:
let
  # ghcr.io/zgeoff/imp-host:<tag>@sha256:<digest>, the form the imp release pin writes
  parsed = builtins.match "ghcr\\.io/zgeoff/imp-host:([^@:]+)@sha256:[0-9a-f]{64}" image;
  tag = builtins.head parsed;
in
if parsed == null then
  [
    "services.imp.image '${image}' names no ghcr.io/zgeoff/imp-host tag and digest"
  ]
else
  lib.optional (tag != releaseVersion)
    "services.imp.image pins imp-host ${tag}, but the imp flake input is release ${releaseVersion}: pin both with bun scripts/release/run-release-pin.ts imp <version>"
