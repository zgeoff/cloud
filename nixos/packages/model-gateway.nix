# nixie's model gateway, which modules/model-gateway.nix runs on the host for production nixie:
# it counts the spend of every model request a nixie sandbox sends and refuses past the limits.
# The release binary with its interpreter patched into the store, since NixOS has no /lib64 loader.
{
  stdenv,
  autoPatchelfHook,
  fetchurl,
}:
let
  version = "0.105.1";
  # sha256sum of the release's model-gateway-linux-x64, which matches the asset's GitHub digest
  sha256 = "45f0103ce50dc6e27a2e04981096cde6873b1b9f00c8cff49a656f525939bc67";
in
stdenv.mkDerivation {
  pname = "model-gateway";
  inherit version;

  src = fetchurl {
    url = "https://github.com/zgeoff/nixie/releases/download/v${version}/model-gateway-linux-x64";
    inherit sha256;
  };

  dontUnpack = true;
  # a Bun single-file executable: stripping drops the .bun section that holds the program
  dontStrip = true;
  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/model-gateway
    runHook postInstall
  '';
}
