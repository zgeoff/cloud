# Evaluates geoffcloud's system derivation, so a change that breaks the host config, or fails one
# of its module assertions, fails this check instead of the switch. It writes the derivation's
# path and builds nothing of the host: the path's string context is discarded, so no output of
# the system derivation becomes an input here.
# Run: bun run test:nixos geoffcloud-eval
{ pkgs, geoffcloud }:
pkgs.writeText "geoffcloud-eval" (
  builtins.unsafeDiscardStringContext geoffcloud.config.system.build.toplevel.drvPath
)
