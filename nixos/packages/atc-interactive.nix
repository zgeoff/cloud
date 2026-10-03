# atc for a shell on the host, such as `atc daemon id`: a copy of the release binary with its
# interpreter patched into the store, since NixOS has no /lib64 loader. The atc daemon runs
# the unpatched binary (atc.nix): an imp target copies the daemon's executable into each
# guest, and this copy would not run there.
{
  stdenv,
  autoPatchelfHook,
  atc,
}:
stdenv.mkDerivation {
  pname = "atc-interactive";
  inherit (atc) version meta;

  src = atc;
  dontUnpack = true;
  # a Bun single-file executable: stripping drops the .bun section that holds the program
  dontStrip = true;
  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src/bin/atc $out/bin/atc
    runHook postInstall
  '';
}
