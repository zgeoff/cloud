# nixie's model gateway, which modules/model-gateway.nix runs on the host for production nixie:
# it counts the spend of every model request a nixie sandbox sends and refuses past the limits.
# The release binary with its interpreter patched into the store, since NixOS has no /lib64 loader.
{
  stdenv,
  autoPatchelfHook,
  fetchurl,
}:
let
  version = "0.84.1";
  # sha256sum of the release's model-gateway-linux-x64, which matches the asset's GitHub digest
  sha256 = "0e70f598c637109c957182014087d07df469a159c81e5f4b451821cb3e84e755";
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
