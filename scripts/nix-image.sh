# shellcheck shell=bash
# The nixos/nix image that scripts/test-nixos.sh and scripts/switch-geoffcloud.sh run Nix in.
# The tag names the Nix release and the digest pins the exact image, so CI's NixOS checks and a
# host switch build with the same Nix, and a run never pulls a moving tag. Refresh the digest from
# the registry when the tag moves, never from memory:
#
#   docker buildx imagetools inspect "nixos/nix:<tag>"
# shellcheck disable=SC2034 # the scripts that source this file read it
NIX_IMAGE='nixos/nix:2.35.2@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c'
