# nixie's counting proxy, which the preview service starts on each preview's model route
# (modules/preview.nix's spendCap). The release binary with its interpreter patched into the
# store, since NixOS has no /lib64 loader and the preview service binds none.
{
  stdenv,
  autoPatchelfHook,
  fetchurl,
}:
let
  version = "0.42.0";
  # sha256sum of the release's counting-proxy-linux-x64, which matches the asset's GitHub digest
  sha256 = "9d699fd1eb6bfcba6a2fdd99e70667755fe29bb1b240f791cf5cc193800cf8cc";
in
stdenv.mkDerivation {
  pname = "counting-proxy";
  inherit version;

  src = fetchurl {
    url = "https://github.com/zgeoff/nixie/releases/download/v${version}/counting-proxy-linux-x64";
    inherit sha256;
  };

  dontUnpack = true;
  # a Bun single-file executable: stripping drops the .bun section that holds the program
  dontStrip = true;
  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/counting-proxy
    runHook postInstall
  '';
}
